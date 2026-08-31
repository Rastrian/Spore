defmodule Spore.ACL do
  @moduledoc false
  import Bitwise

  @spec allow?(tuple()) :: boolean()
  def allow?(ip) do
    allow = Application.get_env(:spore, :allow, [])
    deny = Application.get_env(:spore, :deny, [])

    allowed =
      case allow do
        [] -> true
        _ -> Enum.any?(allow, &match_ip?(ip, &1))
      end

    denied = Enum.any?(deny, &match_ip?(ip, &1))
    allowed and not denied
  end

  @spec parse_list(String.t()) :: list()
  def parse_list(s) when is_binary(s) do
    s
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&parse_entry/1)
    |> Enum.filter(& &1)
  end

  defp parse_entry(entry) do
    case String.split(entry, "/", parts: 2) do
      [ip] ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, addr} -> {:ip, addr}
          _ -> nil
        end

      [ip, masklen] ->
        with {:ok, addr} <- :inet.parse_address(String.to_charlist(ip)),
             {len, ""} <- Integer.parse(masklen) do
          cond do
            tuple_size(addr) == 4 and len >= 0 and len <= 32 -> {:cidr, addr, len}
            tuple_size(addr) == 8 and len >= 0 and len <= 128 -> {:cidr6, addr, len}
            true -> nil
          end
        else
          _ -> nil
        end
    end
  end

  defp match_ip?(ip, {:ip, addr}), do: ip == addr

  defp match_ip?(ip, {:cidr, base, len}) do
    case to_ipv4_mapped(ip) do
      {:ok, v4} -> tuple_size(base) == 4 and v4_match?(v4, base, len)
      :error -> false
    end
  end

  defp match_ip?(ip, {:cidr6, base, len}) do
    case to_ipv4_mapped(ip) do
      {:ok, v4} -> v6_match?(v4_mapped_tuple(v4), base, len)
      :error when tuple_size(ip) == 8 -> v6_match?(ip, base, len)
      _ -> false
    end
  end

  defp match_ip?(_, _), do: false

  # An IPv4 rule must not match a real IPv6 client and vice versa; only the
  # standard ::ffff:0:0/96 v4-mapped block is treated as IPv4.
  defp to_ipv4_mapped(ip) when tuple_size(ip) == 4, do: {:ok, ip}

  defp to_ipv4_mapped({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {:ok, {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}}

  defp to_ipv4_mapped(_), do: :error

  defp v4_mapped_tuple({a, b, c, d}), do: {0, 0, 0, 0, 0, 0xFFFF, a <<< 8 ||| b, c <<< 8 ||| d}

  defp v4_match?(ip, base, len) do
    mask = -1 <<< (32 - len)
    (to_int(ip, 8) &&& mask) == (to_int(base, 8) &&& mask)
  end

  defp v6_match?(ip, base, len) do
    mask = -1 <<< (128 - len)
    (to_int(ip, 16) &&& mask) == (to_int(base, 16) &&& mask)
  end

  # Fold the tuple into one big integer (8 bits per element for IPv4,
  # 16 bits for IPv6), then prefix-compare with an arithmetic mask.
  defp to_int(tuple, bits_per_elem) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn x, acc -> (acc <<< bits_per_elem) + x end)
  end
end
