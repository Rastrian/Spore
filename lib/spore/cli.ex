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
          control_port: :integer,
          sndbuf: :integer,
          recbuf: :integer
        ],
        aliases: [p: :port]
      )

    local_port = Keyword.fetch!(opts, :local_port)
    local_host = Keyword.get(opts, :local_host, "localhost")
    to = Keyword.fetch!(opts, :to)
    port = Keyword.get(opts, :port, 0)
    secret = Keyword.get(opts, :secret, nil)
    control_port = Keyword.get(opts, :control_port, nil)

    if control_port, do: Application.put_env(:spore, :control_port, control_port)
    if sndbuf = Keyword.get(opts, :sndbuf), do: Application.put_env(:spore, :sndbuf, sndbuf)
    if recbuf = Keyword.get(opts, :recbuf), do: Application.put_env(:spore, :recbuf, recbuf)

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
          control_port: :integer,
          sndbuf: :integer,
          recbuf: :integer
        ]
      )

    min_port = Keyword.get(opts, :min_port, 1024)
    max_port = Keyword.get(opts, :max_port, 65535)
    secret = Keyword.get(opts, :secret, nil)
    bind_addr = Keyword.get(opts, :bind_addr, "0.0.0.0")
    bind_tunnels = Keyword.get(opts, :bind_tunnels, nil)
    control_port = Keyword.get(opts, :control_port, nil)

    if control_port, do: Application.put_env(:spore, :control_port, control_port)
    if sndbuf = Keyword.get(opts, :sndbuf), do: Application.put_env(:spore, :sndbuf, sndbuf)
    if recbuf = Keyword.get(opts, :recbuf), do: Application.put_env(:spore, :recbuf, recbuf)

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
      spore local --local-port <PORT> --to <HOST> [--local-host HOST] [--port PORT] [--secret SECRET] [--control-port N] [--sndbuf N] [--recbuf N]
      spore server [--min-port N] [--max-port N] [--secret SECRET] [--bind-addr IP] [--bind-tunnels IP] [--control-port N] [--sndbuf N] [--recbuf N]
    """)
  end
end
