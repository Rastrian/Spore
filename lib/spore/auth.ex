defmodule Spore.Auth do
  @moduledoc """
  HMAC-SHA256 authenticator compatible with Rust `bore`.

  The secret is SHA-256 hashed once and used as the HMAC key.
  Challenges are UUID v4 values serialized in canonical hyphenated form.
  """

  import Bitwise

  @type t :: %{key: binary(), id: String.t()}

  @spec new(String.t()) :: t
  def new(secret) do
    hash = :crypto.hash(:sha256, secret)
    id = Base.encode16(hash, case: :lower)
    %{key: hash, id: id}
  end

  @doc "Create multiple authenticators from a comma-separated list."
  def new_many(secret_or_list) do
    cond do
      is_list(secret_or_list) ->
        Enum.map(secret_or_list, &new/1)

      is_binary(secret_or_list) ->
        secret_or_list
        |> String.split([",", " ", "\n"], trim: true)
        |> Enum.map(&new/1)

      true ->
        []
    end
  end

  @doc "Generate a reply tag for a challenge UUID string."
  @spec answer(t, String.t()) :: String.t()
  def answer(%{key: key}, challenge_uuid_string) do
    tag = :crypto.mac(:hmac, :sha256, key, uuid_to_bytes!(challenge_uuid_string))
    Base.encode16(tag, case: :lower)
  end

  @doc "Validate a reply. Returns true/false."
  @spec validate(t, String.t(), String.t()) :: boolean()
  def validate(%{key: key}, challenge_uuid_string, hex_tag) do
    with {:ok, tag} <- Base.decode16(hex_tag, case: :mixed) do
      expected = :crypto.mac(:hmac, :sha256, key, uuid_to_bytes!(challenge_uuid_string))
      secure_compare(expected, tag)
    else
      _ -> false
    end
  end

  @doc "Server-side handshake: send Challenge and verify Authenticate."
  def server_handshake(%{key: _} = auth, d) do
    challenge = generate_uuid_v4()
    {:ok, _} = Spore.Shared.Delimited.send(d, %{"Challenge" => challenge})

    case Spore.Shared.Delimited.recv_timeout(d) do
      {%{"Authenticate" => tag}, d2} ->
        if validate(auth, challenge, tag) do
          {:ok, d2}
        else
          {{:error, :invalid_secret}, d2}
        end

      {_, d2} ->
        {{:error, :missing_authentication}, d2}
    end
  end

  @doc "Server handshake accepting any of a list of authenticators."
  def server_handshake_many(auths, d) when is_list(auths) and auths != [] do
    challenge = generate_uuid_v4()
    {:ok, _} = Spore.Shared.Delimited.send(d, %{"Challenge" => challenge})

    case Spore.Shared.Delimited.recv_timeout(d) do
      {%{"Authenticate" => tag}, d2} ->
        case Enum.find(auths, fn a -> validate(a, challenge, tag) end) do
          %{id: id} -> {:ok, d2, id}
          _ -> {{:error, :invalid_secret}, d2}
        end

      {_, d2} ->
        {{:error, :missing_authentication}, d2}
    end
  end

  @doc "Client-side handshake: expect Challenge and respond with Authenticate."
  def client_handshake(%{key: _} = auth, d) do
    case Spore.Shared.Delimited.recv_timeout(d) do
      {%{"Challenge" => challenge}, d2} ->
        tag = answer(auth, challenge)
        {:ok, d3} = Spore.Shared.Delimited.send(d2, %{"Authenticate" => tag})
        {:ok, d3}

      {_, d2} ->
        {{:error, :unexpected_no_challenge}, d2}
    end
  end

  @doc "Generate a random UUID v4 as a canonical hyphenated string."
  @spec generate_uuid_v4() :: String.t()
  def generate_uuid_v4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # Set version 4 and variant 2
    c = bor(c, 0x4000) &&& 0x4FFF
    d = bor(d, 0x8000) &&& 0xBFFF

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> to_string()
  end

  @doc "Parse hyphenated UUID string into 16 raw bytes. Raises on error."
  @spec uuid_to_bytes!(String.t()) :: binary()
  def uuid_to_bytes!(uuid) do
    hex = String.replace(uuid, "-", "")

    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == 16 -> bin
      _ -> raise ArgumentError, "invalid UUID: #{uuid}"
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    0 ==
      Enum.reduce(Enum.zip(a_bytes, b_bytes), 0, fn {x, y}, acc -> acc ||| Bitwise.bxor(x, y) end)
  end

  defp secure_compare(_a, _b), do: false
end
