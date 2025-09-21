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

      _ ->
        :ok
    end
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
    _ = :gen_tcp.recv(sock, 0, 100)
    body = render()

    resp = [
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: text/plain; version=0.0.4\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(sock, resp)
    :gen_tcp.close(sock)
  end

  def render do
    rows = :ets.tab2list(@metrics_table)

    Enum.map_join(rows, "\n", fn {name, value} ->
      ["# TYPE ", Atom.to_string(name), " counter\n", Atom.to_string(name), " ", to_string(value)]
    end) <> "\n"
  end
end
