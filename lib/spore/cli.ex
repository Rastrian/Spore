defmodule Spore.CLI do
  @moduledoc false
  require Logger

  def main(argv) do
    Logger.configure(level: :info)

    case argv do
      ["local" | rest] -> local(rest)
      ["server" | rest] -> server(rest)
      _ -> usage(:stderr)
    end
  end

  defp local(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          local_port: :integer,
          local_host: :string,
          to: :string,
          port: :integer,
          secret: :string,
          config: :string,
          control_port: :integer,
          tls: :boolean,
          cacertfile: :string,
          insecure: :boolean,
          certfile: :string,
          keyfile: :string,
          sndbuf: :integer,
          recbuf: :integer,
          otel_enable: :boolean,
          otel_endpoint: :string,
          json_logs: :boolean
        ],
        aliases: [p: :port]
      )

    local_port = Keyword.fetch!(opts, :local_port)
    local_host = Keyword.get(opts, :local_host, "localhost")
    to = Keyword.fetch!(opts, :to)
    port = Keyword.get(opts, :port, 0)
    secret = Keyword.get(opts, :secret, nil)
    control_port = Keyword.get(opts, :control_port, nil)

    if cfg = Keyword.get(opts, :config),
      do:
        (
          Application.put_env(:spore, :config_path, cfg)
          load_config(cfg)
        )

    if control_port, do: Application.put_env(:spore, :control_port, control_port)
    if Keyword.get(opts, :tls), do: Application.put_env(:spore, :tls, true)

    if cacert = Keyword.get(opts, :cacertfile),
      do: Application.put_env(:spore, :cacertfile, cacert)

    if Keyword.get(opts, :insecure), do: Application.put_env(:spore, :ssl_verify, false)

    if cert = Keyword.get(opts, :certfile),
      do: Application.put_env(:spore, :client_certfile, cert)

    if key = Keyword.get(opts, :keyfile), do: Application.put_env(:spore, :client_keyfile, key)
    if sndbuf = Keyword.get(opts, :sndbuf), do: Application.put_env(:spore, :sndbuf, sndbuf)
    if recbuf = Keyword.get(opts, :recbuf), do: Application.put_env(:spore, :recbuf, recbuf)
    if Keyword.get(opts, :otel_enable), do: Application.put_env(:spore, :otel_enable, true)
    if ep = Keyword.get(opts, :otel_endpoint), do: Application.put_env(:spore, :otel_endpoint, ep)
    if Keyword.get(opts, :json_logs), do: Application.put_env(:spore, :json_logs, true)

    case Spore.Client.new(local_host, local_port, to, port, secret) do
      {:ok, client} ->
        case Spore.Client.listen(client) do
          :ok -> :ok
          {:error, err} -> Logger.error("client exited: #{inspect(err)}")
        end

      {:error, err} ->
        Logger.error("failed to start client: #{inspect(err)}")
    end
  end

  defp server(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          min_port: :integer,
          max_port: :integer,
          secret: :string,
          bind_addr: :string,
          bind_tunnels: :string,
          config: :string,
          control_port: :integer,
          tls: :boolean,
          certfile: :string,
          keyfile: :string,
          allow: :string,
          deny: :string,
          max_conns_per_ip: :integer,
          metrics_port: :integer,
          sndbuf: :integer,
          recbuf: :integer,
          otel_enable: :boolean,
          otel_endpoint: :string,
          json_logs: :boolean
        ]
      )

    min_port = Keyword.get(opts, :min_port, 1024)
    max_port = Keyword.get(opts, :max_port, 65535)
    secret = Keyword.get(opts, :secret, nil)
    bind_addr = Keyword.get(opts, :bind_addr, "0.0.0.0")
    bind_tunnels = Keyword.get(opts, :bind_tunnels, nil)
    control_port = Keyword.get(opts, :control_port, nil)

    if cfg = Keyword.get(opts, :config),
      do:
        (
          Application.put_env(:spore, :config_path, cfg)
          load_config(cfg)
        )

    if control_port, do: Application.put_env(:spore, :control_port, control_port)
    if Keyword.get(opts, :tls), do: Application.put_env(:spore, :tls, true)
    if cert = Keyword.get(opts, :certfile), do: Application.put_env(:spore, :certfile, cert)
    if key = Keyword.get(opts, :keyfile), do: Application.put_env(:spore, :keyfile, key)

    if allow = Keyword.get(opts, :allow),
      do: Application.put_env(:spore, :allow, Spore.ACL.parse_list(allow))

    if deny = Keyword.get(opts, :deny),
      do: Application.put_env(:spore, :deny, Spore.ACL.parse_list(deny))

    if m = Keyword.get(opts, :max_conns_per_ip),
      do: Application.put_env(:spore, :max_conns_per_ip, m)

    if sndbuf = Keyword.get(opts, :sndbuf), do: Application.put_env(:spore, :sndbuf, sndbuf)
    if recbuf = Keyword.get(opts, :recbuf), do: Application.put_env(:spore, :recbuf, recbuf)
    if mp = Keyword.get(opts, :metrics_port), do: Application.put_env(:spore, :metrics_port, mp)
    if Keyword.get(opts, :otel_enable), do: Application.put_env(:spore, :otel_enable, true)
    if ep = Keyword.get(opts, :otel_endpoint), do: Application.put_env(:spore, :otel_endpoint, ep)
    if Keyword.get(opts, :json_logs), do: Application.put_env(:spore, :json_logs, true)

    case Spore.Server.listen(
           min_port: min_port,
           max_port: max_port,
           secret: secret,
           bind_addr: bind_addr,
           bind_tunnels: bind_tunnels
         ) do
      :ok -> :ok
      {:error, err} -> Logger.error("server error: #{inspect(err)}")
    end
  end

  defp usage(io) do
    IO.puts(io, """
    Usage:
      spore local --local-port <PORT> --to <HOST> [--local-host HOST] [--port PORT] [--secret SECRET] [--config FILE.json] [--control-port N] [--tls] [--cacertfile PATH] [--certfile PATH] [--keyfile PATH] [--insecure] [--sndbuf N] [--recbuf N] [--otel-enable] [--otel-endpoint URL] [--json-logs]
      spore server [--min-port N] [--max-port N] [--secret SECRET] [--bind-addr IP] [--bind-tunnels IP] [--config FILE.json] [--control-port N] [--tls] [--certfile PATH] [--keyfile PATH] [--allow CIDRs] [--deny CIDRs] [--max-conns-per-ip N] [--sndbuf N] [--recbuf N] [--metrics-port N] [--otel-enable] [--otel-endpoint URL] [--json-logs]
    """)
  end

  defp load_config(path), do: Spore.Config.load_file(path)
end
