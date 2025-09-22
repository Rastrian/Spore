defmodule Spore.Metrics do
  @moduledoc false
  use GenServer
  require Logger

  @metrics_table :spore_metrics
  @accept_ts_table :spore_accept_ts

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    _ = :ets.new(@metrics_table, [:set, :named_table, :public])
    _ = :ets.new(@accept_ts_table, [:set, :named_table, :public])
    maybe_start_http()
    {:ok, %{server: nil}}
  end

  def inc(name, delta \\ 1) when is_atom(name) do
    try do
      :ets.update_counter(@metrics_table, name, {2, delta}, {name, 0})
    rescue
      _ -> :ok
    end
  end

  def note_pending(id) do
    :ets.insert(@accept_ts_table, {id, System.monotonic_time(:millisecond)})
    inc(:spore_connections_incoming_total, 1)
  end

  def note_accept(id) do
    now = System.monotonic_time(:millisecond)

    case :ets.take(@accept_ts_table, id) do
      [{^id, ts}] ->
        inc(:spore_connections_accepted_total, 1)
        inc(:spore_accept_latency_ms_sum, max(0, now - ts))
        inc(:spore_accept_latency_ms_count, 1)
        bucket(now - ts)

      _ ->
        :ok
    end
  end

  defp bucket(ms) do
    for le <- [5, 10, 25, 50, 100, 250, 500, 1000, 2000, 5000] do
      if ms <= le do
        inc(String.to_atom("spore_accept_latency_ms_bucket_le_" <> Integer.to_string(le)), 1)
      end
    end

    inc(:spore_accept_latency_ms_bucket_le_inf, 1)
  end

  def track_bytes(n) when is_integer(n) and n > 0, do: inc(:spore_bytes_proxied_total, n)

  def stale(), do: inc(:spore_connections_stale_total, 1)

  defp maybe_start_http do
    case Application.get_env(:spore, :metrics_port) do
      nil -> :ok
      port when is_integer(port) -> Task.start(fn -> run_http(port) end)
    end
  end

  defp run_http(port) do
    case :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true]) do
      {:ok, ls} ->
        Logger.info("metrics listening on :#{port}")
        accept_loop(ls)

      {:error, err} ->
        Logger.error("metrics listen failed: #{inspect(err)}")
    end
  end

  defp accept_loop(ls) do
    case :gen_tcp.accept(ls) do
      {:ok, sock} ->
        Task.start(fn -> serve(sock) end)
        accept_loop(ls)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock) do
    with {:ok, req} <- :gen_tcp.recv(sock, 0, 200) do
      first = req |> to_string() |> String.split("\r\n", parts: 2) |> hd()

      route =
        cond do
          String.starts_with?(first, "GET /metrics") ->
            :metrics

          String.starts_with?(first, "POST /reload") or String.starts_with?(first, "GET /reload") ->
            :reload

          String.starts_with?(first, "GET /state") ->
            :state

          true ->
            :metrics
        end

      case route do
        :metrics ->
          reply_text(sock, render(), "text/plain; version=0.0.4")

        :reload ->
          case Spore.Config.reload_from_env() do
            {:ok, _} -> reply_text(sock, "ok\n", "text/plain")
            {:error, _} -> reply_text(sock, "no-config\n", "text/plain")
          end

        :state ->
          body = state_render()
          reply_text(sock, body, "application/json")
      end
    end

    :gen_tcp.close(sock)
  end

  defp reply_text(sock, body, ctype) do
    resp = [
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: ",
      ctype,
      "\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(sock, resp)
  end

  def render do
    rows = :ets.tab2list(@metrics_table)
    per_ip = Spore.Limits.snapshot()
    pending = DynamicSupervisor.count_children(Spore.Pending.Supervisor).active

    base = Enum.map(rows, fn {name, value} ->
      ["# TYPE ", Atom.to_string(name), " counter\n", Atom.to_string(name), " ", to_string(value), "\n"]
    end)
    ip_lines = Enum.map(per_ip, fn {ip, count} ->
      ["spore_conns_by_ip{ip=\"", :inet.ntoa(ip) |> to_string(), "\"} ", Integer.to_string(count), "\n"]
    end)
    pending_line = ["spore_pending_active ", Integer.to_string(pending), "\n"]
    IO.iodata_to_binary(base ++ ip_lines ++ [pending_line])
  end

  defp state_render do
    Jason.encode!(%{
      control_port: Application.get_env(:spore, :control_port),
      tls: Application.get_env(:spore, :tls),
      allow: Application.get_env(:spore, :allow),
      deny: Application.get_env(:spore, :deny),
      max_conns_per_ip: Application.get_env(:spore, :max_conns_per_ip),
      max_pending: Application.get_env(:spore, :max_pending),
      metrics_port: Application.get_env(:spore, :metrics_port)
    })
  end
end
