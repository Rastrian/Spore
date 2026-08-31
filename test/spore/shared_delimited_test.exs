defmodule Spore.SharedDelimitedTest do
  use ExUnit.Case, async: false

  alias Spore.Shared.Delimited

  @localhost {127, 0, 0, 1}
  @socket_opts [:binary, active: false, packet: 0, nodelay: true, reuseaddr: true, ip: @localhost]

  setup do
    {client, server} = socket_pair()

    on_exit(fn ->
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end)

    %{client: client, server: server}
  end

  describe "send/2 and recv/2" do
    test "round-trips a JSON map over a real socket pair", %{client: client, server: server} do
      d_client = Delimited.new(client, :gen_tcp)
      assert {:ok, %Delimited{}} = Delimited.send(d_client, %{"Hello" => 1234})

      {value, d2} = Delimited.recv(Delimited.new(server, :gen_tcp), 2000)
      assert value == %{"Hello" => 1234}
      assert %Delimited{buffer: <<>>} = d2
    end

    test "round-trips strings, numbers, lists, nil and booleans", %{
      client: client,
      server: server
    } do
      d_sender = Delimited.new(client, :gen_tcp)
      d = Delimited.new(server, :gen_tcp)

      Enum.reduce(["Heartbeat", 42, [1, 2, 3], nil, true], d, fn value, _acc ->
        assert {:ok, %Delimited{}} = Delimited.send(d_sender, value)
        assert {^value, _acc} = Delimited.recv(d, 2000)
      end)
    end

    test "two frames delivered in a single packet decode one per recv", %{
      client: client,
      server: server
    } do
      first = Jason.encode!(%{"Hello" => 1})
      second = Jason.encode!("Heartbeat")
      :ok = :gen_tcp.send(client, [first, <<0>>, second, <<0>>])

      d = Delimited.new(server, :gen_tcp)
      {v1, d2} = Delimited.recv(d, 2000)
      assert v1 == %{"Hello" => 1}
      # The second frame stays in the buffer, no extra socket read needed.
      assert d2.buffer == second <> <<0>>

      {v2, d3} = Delimited.recv(d2, 2000)
      assert v2 == "Heartbeat"
      assert d3.buffer == <<>>
    end

    test "the leftover buffer persists across recv calls", %{client: client, server: server} do
      d_sender = Delimited.new(client, :gen_tcp)

      Enum.reduce(1..3, d_sender, fn i, acc ->
        assert {:ok, acc} = Delimited.send(acc, %{"Ping" => i})
        acc
      end)

      d = Delimited.new(server, :gen_tcp)

      Enum.reduce(1..3, d, fn i, acc ->
        {value, acc} = Delimited.recv(acc, 2000)
        assert value == %{"Ping" => i}
        acc
      end)
    end

    test "a non-JSON frame yields a tagged decode error", %{client: client, server: server} do
      :ok = :gen_tcp.send(client, ["this is not json", <<0>>])
      d = Delimited.new(server, :gen_tcp)

      assert {{:error, {:decode_error, _}}, %Delimited{}} = Delimited.recv(d, 2000)
    end

    test "recv with a tiny timeout on an idle socket returns :timeout", %{server: server} do
      d = Delimited.new(server, :gen_tcp)

      assert {{:error, :timeout}, %Delimited{}} = Delimited.recv(d, 100)
      assert {{:error, :timeout}, %Delimited{}} = Delimited.recv_timeout(d, 100)
    end

    test "peer close yields :eof", %{client: client, server: server} do
      :ok = :gen_tcp.close(client)
      d = Delimited.new(server, :gen_tcp)

      assert {:eof, %Delimited{}} = Delimited.recv(d, 2000)
    end

    test "accumulating more than max_frame_length bytes without a delimiter fails", %{
      client: client,
      server: server
    } do
      assert Spore.Shared.max_frame_length() == 256
      :ok = :gen_tcp.send(client, :binary.copy("A", 300))
      d = Delimited.new(server, :gen_tcp)

      assert {{:error, :frame_too_large}, %Delimited{}} = Delimited.recv(d, 3000)
    end

    test "exactly max_frame_length undelimited bytes are still under the limit and time out", %{
      client: client,
      server: server
    } do
      :ok = :gen_tcp.send(client, :binary.copy("A", 256))
      d = Delimited.new(server, :gen_tcp)

      assert {{:error, :timeout}, %Delimited{}} = Delimited.recv(d, 150)
    end
  end

  defp socket_pair do
    {:ok, listener} = :gen_tcp.listen(0, @socket_opts)
    {:ok, port} = :inet.port(listener)

    {:ok, client} =
      :gen_tcp.connect(@localhost, port, [:binary, active: false, packet: 0, nodelay: true], 5000)

    {:ok, server} = :gen_tcp.accept(listener, 5000)
    :gen_tcp.close(listener)

    {client, server}
  end
end
