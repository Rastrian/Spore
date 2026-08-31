defmodule Spore.JsonFormatter do
  @moduledoc false

  # Formatter used when --json-logs is enabled. Spore.Application wires it
  # into the default :logger handler as a `{module, function}` template,
  # which means :logger calls it as format(level, message, timestamp,
  # metadata) — four flat arguments, NOT the legacy
  # (level, gl, {Logger, msg, ts, md}, opts) tuple contract.
  @spec format(Logger.level(), Logger.message(), Logger.Formatter.time(), keyword()) ::
          IO.chardata()
  def format(level, msg, ts, metadata) do
    map = %{
      time: format_time(ts),
      level: to_string(level),
      message: msg_to_binary(msg),
      module: metadata[:module],
      function: metadata[:function],
      line: metadata[:line],
      pid: inspect(metadata[:pid] || self())
    }

    # Enum.reject/2 over a map returns a list of {key, value} tuples, which
    # Jason cannot encode — convert back to a map before encoding so the
    # nil-valued keys are simply omitted.
    [Jason.encode!(Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()), "\n"]
  end

  defp format_time({date, time}) do
    {{y, m, d}, {hh, mm, ss, _ms}} = {date, time}

    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [y, m, d, hh, mm, ss])
    |> IO.iodata_to_binary()
  end

  defp msg_to_binary(msg) when is_binary(msg), do: msg

  defp msg_to_binary(msg) when is_list(msg) do
    try do
      IO.iodata_to_binary(msg)
    rescue
      _ -> inspect(msg)
    end
  end

  defp msg_to_binary(msg), do: inspect(msg)
end
