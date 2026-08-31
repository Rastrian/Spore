defmodule Spore.CLI do
  @moduledoc false
  require Logger

  @server_switches [
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

  @local_switches [
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
    retry: :boolean,
    retry_delay_ms: :integer,
    otel_enable: :boolean,
    otel_endpoint: :string,
    json_logs: :boolean
  ]

  def main(argv) do
    Logger.configure(level: :info)

    case argv do
      ["update" | rest] ->
        # In the mix release daemon `bin/spore` needs a release command, so
        # `spore update` reaches this through `bin/spore eval` (see
        # Spore.SelfUpdate's moduledoc). The eval node has no supervision
        # tree, hence no baked config (e.g. :spore, :version) and no Logger
        # handlers: start the application ourselves first.
        System.delete_env("SPORE_ARGS")

        case Application.ensure_all_started(:spore) do
          {:ok, _apps} ->
            case Spore.SelfUpdate.run(rest) do
              :ok -> :ok
              {:error, err} -> Logger.error("update failed: #{inspect(err)}")
            end

          {:error, reason} ->
            Logger.error("update failed: could not start spore: #{inspect(reason)}")
        end

      ["local" | rest] ->
        local(rest)

      ["server" | rest] ->
        server(rest)

      _ ->
        usage(:stderr)
    end
  end

  defp local(args) do
    client_opts = apply_local_opts(args)

    case Spore.Client.new(
           client_opts.local_host,
           client_opts.local_port,
           client_opts.to,
           client_opts.port,
           client_opts.secret
         ) do
      {:ok, client} ->
        case Spore.Client.listen(client) do
          :ok -> :ok
          {:error, err} -> Logger.error("client exited: #{inspect(err)}")
        end

      {:error, err} ->
        Logger.error("failed to start client: #{inspect(err)}")
    end
  end

  @doc """
  Parse the argv of a `spore local` invocation (without the leading "local"),
  apply it to the application environment and return the connection opts for
  `Spore.Client.new/5`. Like the Rust original, the local port may be passed
  positionally (`local 9573 --to HOST`) or through `--local-port`, which wins.

  Shared by the escript `local` command and by the release boot path, which
  receives the same argv through the `SPORE_ARGS` environment variable before
  the supervision tree starts.
  """
  @spec apply_local_opts([String.t()]) :: %{
          local_host: String.t(),
          local_port: non_neg_integer(),
          to: String.t(),
          port: non_neg_integer(),
          secret: String.t() | nil
        }
  def apply_local_opts(args) do
    {opts, positional, _} =
      OptionParser.parse(args, switches: @local_switches, aliases: [p: :port])

    local_port = Keyword.get(opts, :local_port) || positional_port(positional)
    local_host = Keyword.get(opts, :local_host, "localhost")
    to = Keyword.fetch!(opts, :to)
    port = Keyword.get(opts, :port, 0)
    secret = Keyword.get(opts, :secret, nil) || System.get_env("SPORE_SECRET")
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
    if Keyword.get(opts, :retry), do: Application.put_env(:spore, :retry, true)

    if d = Keyword.get(opts, :retry_delay_ms),
      do: Application.put_env(:spore, :retry_delay_ms, d)

    # The reconnect path re-authenticates from this value; the HMAC key kept
    # in the authenticator is the SHA-256 of the secret, not the secret.
    if secret, do: Application.put_env(:spore, :last_secret, secret)
    if Keyword.get(opts, :otel_enable), do: Application.put_env(:spore, :otel_enable, true)
    if ep = Keyword.get(opts, :otel_endpoint), do: Application.put_env(:spore, :otel_endpoint, ep)
    if Keyword.get(opts, :json_logs), do: Application.put_env(:spore, :json_logs, true)

    maybe_start_metrics()

    %{
      local_host: local_host,
      local_port: local_port,
      to: to,
      port: port,
      secret: secret
    }
  end

  @doc """
  Parse the argv of a `spore server` invocation and apply it to the application
  environment, returning the opts accepted by `Spore.Server.listen/1`.

  Shared by the escript `server` command and by the release boot path, which
  receives the same argv through the `SPORE_ARGS` environment variable before
  the supervision tree starts.
  """
  @spec apply_server_opts([String.t()]) :: Spore.Server.opts()
  def apply_server_opts(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @server_switches)

    min_port = Keyword.get(opts, :min_port, 1024)
    max_port = Keyword.get(opts, :max_port, 65535)
    secret = Keyword.get(opts, :secret, nil) || System.get_env("SPORE_SECRET")
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

    [
      min_port: min_port,
      max_port: max_port,
      secret: secret,
      bind_addr: bind_addr,
      bind_tunnels: bind_tunnels
    ]
  end

  defp server(args) do
    server_opts = apply_server_opts(args)
    maybe_start_metrics()

    case Spore.Server.listen(server_opts) do
      :ok -> :ok
      {:error, err} -> Logger.error("server error: #{inspect(err)}")
    end
  end

  defp maybe_start_metrics do
    # The release boot path parses argv before the supervision tree exists;
    # there the Spore.Metrics child starts the listener itself, so only call
    # into it when the server is already up (escript path).
    if Application.get_env(:spore, :metrics_port) && Process.whereis(Spore.Metrics),
      do: Spore.Metrics.start_http()

    :ok
  end

  defp positional_port([port | _]), do: String.to_integer(port)

  defp positional_port([]),
    do: raise(ArgumentError, "missing local port, pass it positionally or via --local-port")

  defp usage(io) do
    IO.puts(io, """
    Usage:
      spore local [PORT] --to <HOST> [--local-port <PORT>] [--local-host HOST] [--port PORT] [--secret SECRET] [--config FILE.json] [--control-port N] [--tls] [--cacertfile PATH] [--certfile PATH] [--keyfile PATH] [--insecure] [--sndbuf N] [--recbuf N] [--retry] [--retry-delay-ms N] [--otel-enable] [--otel-endpoint URL] [--json-logs]
      spore server [--min-port N] [--max-port N] [--secret SECRET] [--bind-addr IP] [--bind-tunnels IP] [--config FILE.json] [--control-port N] [--tls] [--certfile PATH] [--keyfile PATH] [--allow CIDRs] [--deny CIDRs] [--max-conns-per-ip N] [--sndbuf N] [--recbuf N] [--metrics-port N] [--otel-enable] [--otel-endpoint URL] [--json-logs]
      spore update [--check] [--version vX.Y.Z] [--repo OWNER/REPO] [--restart] [--install-root DIR]
    """)
  end

  defp load_config(path), do: Spore.Config.load_file(path)
end
