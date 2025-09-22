defmodule Spore.Shared do
  @moduledoc """
  Shared protocol and IO utilities compatible with Rust `bore`.

  - JSON messages delimited by a single null byte (0x00)
  - Externally tagged enum-style JSON: maps like %{"Hello" => 1234} or strings like "Heartbeat"
  """

  @control_port 7835
  @max_frame_length 256
  @network_timeout_ms 3_000

  @doc "TCP port used for control connections with the server. Can be overridden via Application env :spore, :control_port."
  def control_port do
    Application.get_env(:spore, :control_port, @control_port)
  end

  @doc "Default timeout for initial network operations (ms)."
  def network_timeout_ms, do: @network_timeout_ms

  @doc "Maximum JSON frame length in bytes."
  def max_frame_length, do: @max_frame_length

  @type socket :: :gen_tcp.socket()

  defmodule Delimited do
    @moduledoc "Delimited JSON transport wrapping a passive TCP socket."
    defstruct [:socket, :io_mod, buffer: <<>>]

    @type t :: %__MODULE__{socket: Spore.Shared.socket(), io_mod: module(), buffer: binary()}

    @doc "Wrap a passive socket with IO module (:gen_tcp or :ssl)."
    @spec new(Spore.Shared.socket(), module()) :: t
    def new(socket, io_mod), do: %__MODULE__{socket: socket, io_mod: io_mod, buffer: <<>>}

    @doc "Receive next null-delimited JSON value. Returns {value, updated_transport}."
    @spec recv(t, timeout()) :: {any() | :eof | {:error, term()}, t}
    def recv(%__MODULE__{} = d, timeout \\ :infinity) do
      case read_frame(d, timeout) do
        {:ok, frame, d2} ->
          case Jason.decode(frame) do
            {:ok, value} -> {value, d2}
            {:error, err} -> {{:error, {:decode_error, err}}, d2}
          end

        {:eof, d2} ->
          {:eof, d2}

        {:error, err, d2} ->
          {{:error, err}, d2}
      end
    end

    @doc "Receive with default network timeout for initial handshakes."
    @spec recv_timeout(t) :: {any() | :eof | {:error, term()}, t}
    def recv_timeout(%__MODULE__{} = d) do
      recv(d, Spore.Shared.network_timeout_ms())
    end

    @doc "Send a JSON value followed by a null terminator. Returns updated transport."
    @spec send(t, any()) :: {:ok, t} | {:error, term()}
    def send(%__MODULE__{socket: socket, io_mod: io_mod} = d, value) do
      with {:ok, json} <- Jason.encode(value),
           :ok <- io_mod.send(socket, [json, <<0>>]) do
        {:ok, d}
      else
        {:error, _} = err -> err
      end
    end

    defp read_frame(%__MODULE__{socket: socket, io_mod: io_mod, buffer: buf} = d, timeout) do
      case :binary.match(buf, <<0>>) do
        {idx, 1} ->
          <<frame::binary-size(idx), _zero, rest::binary>> = buf
          {:ok, frame, %{d | buffer: rest}}

        :nomatch ->
          case io_mod.recv(socket, 0, timeout) do
            {:ok, more} ->
              new = buf <> more

              if byte_size(new) > Spore.Shared.max_frame_length() do
                {:error, :frame_too_large, %{d | buffer: new}}
              else
                read_frame(%{d | buffer: new}, timeout)
              end

            {:error, :timeout} ->
              {:error, :timeout, d}

            {:error, :closed} ->
              {:eof, d}

            {:error, reason} ->
              {:error, reason, d}
          end
      end
    end
  end

  @doc "Connect with timeout, returning a passive, binary-mode socket."
  @spec connect(String.t(), :inet.port_number(), timeout()) :: {:ok, socket()} | {:error, term()}
  def connect(host, port, timeout_ms) do
    case transport_mod() do
      :gen_tcp ->
        result =
          :gen_tcp.connect(
            String.to_charlist(host),
            port,
            [:binary, active: false, packet: 0, nodelay: true, reuseaddr: true],
            timeout_ms
          )

        case result do
          {:ok, socket} ->
            _ = tune_socket(socket)
            {:ok, socket}

          other ->
            other
        end

      :ssl ->
        ssl_opts = ssl_client_opts()
        apply(:ssl, :connect, [String.to_charlist(host), port, ssl_opts, timeout_ms])
    end
  end

  def transport_mod do
    if Application.get_env(:spore, :tls, false), do: :ssl, else: :gen_tcp
  end

  @doc "Return socket tuning options from application env."
  def socket_tune_opts do
    opts = []

    opts =
      case Application.get_env(:spore, :sndbuf) do
        n when is_integer(n) and n > 0 -> [{:sndbuf, n} | opts]
        _ -> opts
      end

    opts =
      case Application.get_env(:spore, :recbuf) do
        n when is_integer(n) and n > 0 -> [{:recbuf, n} | opts]
        _ -> opts
      end

    opts
  end

  @doc "Apply tuning options to a socket."
  def tune_socket(socket) do
    opts = socket_tune_opts()

    case opts do
      [] -> :ok
      _ -> :inet.setopts(socket, opts)
    end
  end

  defp ssl_client_opts do
    verify =
      if Application.get_env(:spore, :ssl_verify, true), do: :verify_peer, else: :verify_none

    base = [active: false, verify: verify]
    cacertfile = Application.get_env(:spore, :cacertfile)

    base =
      if is_binary(cacertfile),
        do: [{:cacertfile, String.to_charlist(cacertfile)} | base],
        else: base

    certfile = Application.get_env(:spore, :client_certfile)
    keyfile = Application.get_env(:spore, :client_keyfile)

    base =
      if is_binary(certfile) and is_binary(keyfile),
        do: [
          {:certfile, String.to_charlist(certfile)},
          {:keyfile, String.to_charlist(keyfile)} | base
        ],
        else: base

    base
  end

  @doc "Bidirectionally pipe data between two sockets until either closes."
  @spec pipe_bidirectional(socket(), socket()) :: :ok
  def pipe_bidirectional(a, b) do
    left = Task.async(fn -> pipe(a, :gen_tcp, b, :gen_tcp) end)
    right = Task.async(fn -> pipe(b, :gen_tcp, a, :gen_tcp) end)
    ref_left = Process.monitor(left.pid)
    ref_right = Process.monitor(right.pid)

    receive do
      {:DOWN, ^ref_left, :process, _pid, _} -> :ok
      {:DOWN, ^ref_right, :process, _pid, _} -> :ok
    end

    Task.shutdown(left, :brutal_kill)
    Task.shutdown(right, :brutal_kill)
    :gen_tcp.close(a)
    :gen_tcp.close(b)
    :ok
  end

  @doc "Bidirectionally pipe with explicit transport modules."
  @spec pipe_bidirectional(socket(), module(), socket(), module()) :: :ok
  def pipe_bidirectional(a, amod, b, bmod) do
    left = Task.async(fn -> pipe(a, amod, b, bmod) end)
    right = Task.async(fn -> pipe(b, bmod, a, amod) end)
    ref_left = Process.monitor(left.pid)
    ref_right = Process.monitor(right.pid)

    receive do
      {:DOWN, ^ref_left, :process, _pid, _} -> :ok
      {:DOWN, ^ref_right, :process, _pid, _} -> :ok
    end

    Task.shutdown(left, :brutal_kill)
    Task.shutdown(right, :brutal_kill)
    close(a, amod)
    close(b, bmod)
    :ok
  end

  defp pipe(src, src_mod, dst, dst_mod) do
    case src_mod.recv(src, 0) do
      {:ok, data} ->
        _ = dst_mod.send(dst, data)
        Spore.Metrics.track_bytes(byte_size(data))
        pipe(src, src_mod, dst, dst_mod)

      {:error, _} ->
        :ok
    end
  end

  defp close(socket, :gen_tcp), do: :gen_tcp.close(socket)
  defp close(socket, :ssl), do: apply(:ssl, :close, [socket])
end
