defmodule Spore.JsonFormatter do
  @moduledoc false
  @spec format(atom(), pid(), {Logger, Logger.message(), Logger.Formatter.time(), keyword()}, keyword()) :: IO.chardata()
  def format(_level, _gl, {Logger, msg, ts, md}, _opts) do
    map = %{
      time: format_time(ts),
      level: md[:level] || "info",
      message: iodata_to_binary(msg),
      module: md[:module],
      function: md[:function],
      line: md[:line],
      pid: inspect(md[:pid] || self())
    }
    [Jason.encode!(Enum.reject(map, fn {_k, v} -> is_nil(v) end)), "\n"]
  end

  defp format_time({date, time}) do
    {{y, m, d}, {hh, mm, ss, _ms}} = {date, time}
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [y, m, d, hh, mm, ss]) |> IO.iodata_to_binary()
  end

  defp iodata_to_binary(data) when is_binary(data), do: data
  defp iodata_to_binary(data), do: IO.iodata_to_binary(data)
end
