defmodule Spore.Shared do
  @moduledoc """
  Shared protocol and IO utilities compatible with Rust `bore`.

  - JSON messages delimited by a single null byte (0x00)
  - Externally tagged enum-style JSON: maps like %{"Hello" => 1234} or strings like "Heartbeat"
  """

  @control_port 7835
  @max_frame_length 256
  @network_timeout_ms 3_000

  @doc "TCP port used for control connections with the server."
  def control_port, do: @control_port

  @doc "Default timeout for initial network operations (ms)."
  def network_timeout_ms, do: @network_timeout_ms

  @doc "Maximum JSON frame length in bytes."
  def max_frame_length, do: @max_frame_length

  @type socket :: :gen_tcp.socket()

  defmodule Delimited do
    @moduledoc "Delimited JSON transport wrapping a passive TCP socket."
    defstruct [:socket, buffer: <<>>]

    @type t :: %__MODULE__{socket: Spore.Shared.socket(), buffer: binary()}

    @doc "Wrap a passive, binary-mode TCP socket."
    @spec new(Spore.Shared.socket()) :: t
    def new(socket), do: %__MODULE__{socket: socket, buffer: <<>>}

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
    def send(%__MODULE__{socket: socket} = d, value) do
      with {:ok, json} <- Jason.encode(value),
           :ok <- :gen_tcp.send(socket, [json, <<0>>]) do
        {:ok, d}
      else
        {:error, _} = err -> err
      end
    end

    defp read_frame(%__MODULE__{socket: socket, buffer: buf} = d, timeout) do
      case :binary.match(buf, <<0>>) do
        {idx, 1} ->
          <<frame::binary-size(idx), _zero, rest::binary>> = buf
          {:ok, frame, %{d | buffer: rest}}

        :nomatch ->
          case :gen_tcp.recv(socket, 0, timeout) do
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
    :gen_tcp.connect(
      String.to_charlist(host),
      port,
      [:binary, active: false, packet: 0, nodelay: true, reuseaddr: true],
      timeout_ms
    )
  end

  @doc "Bidirectionally pipe data between two sockets until either closes."
  @spec pipe_bidirectional(socket(), socket()) :: :ok
  def pipe_bidirectional(a, b) do
    left = Task.async(fn -> pipe(a, b) end)
    right = Task.async(fn -> pipe(b, a) end)
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

  defp pipe(src, dst) do
    case :gen_tcp.recv(src, 0) do
      {:ok, data} ->
        _ = :gen_tcp.send(dst, data)
        pipe(src, dst)

      {:error, _} ->
        :ok
    end
  end
end
