defmodule Spore.ACL do
  @moduledoc false
  import Bitwise

  @spec allow?(tuple()) :: boolean()
  def allow?(ip) do
    allow = Application.get_env(:spore, :allow, [])
    deny = Application.get_env(:spore, :deny, [])

    allowed = case allow do
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
          {:cidr, addr, len}
        else
          _ -> nil
        end
    end
  end

  defp match_ip?(ip, {:ip, addr}), do: ip == addr
  defp match_ip?({a,b,c,d}, {:cidr, {a2,b2,c2,d2}, len}) when is_integer(len) and len>=0 and len<=32 do
    mask = bnot((1 <<< (32 - len)) - 1) &&& 0xFFFFFFFF
    ipi = (a<<<24) + (b<<<16) + (c<<<8) + d
    base = (a2<<<24) + (b2<<<16) + (c2<<<8) + d2
    (ipi &&& mask) == (base &&& mask)
  end
  defp match_ip?({_,_,_,_,_,_,_,_}, {:cidr, _, _}), do: false
  defp match_ip?(_, _), do: false
end
