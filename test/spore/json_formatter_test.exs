defmodule Spore.JsonFormatterTest do
  use ExUnit.Case, async: false

  alias Spore.JsonFormatter

  @ts {{2026, 8, 30}, {12, 34, 56, 789}}

  # The formatter is wired into the default :logger handler as a
  # {module, function} template (see Spore.Application), so :logger calls it
  # with four flat arguments: format(level, message, timestamp, metadata).
  describe "format/4 (flat :logger template contract)" do
    test "renders a single JSON line terminated by a newline" do
      out = JsonFormatter.format(:info, "hello", @ts, module: Spore.Auth, line: 10, pid: self())

      assert is_list(out)

      line = IO.iodata_to_binary(out)
      assert String.ends_with?(line, "\n")
      assert line |> String.trim_trailing() |> String.split("\n") |> length() == 1

      assert Jason.decode!(line) == %{
               "time" => "2026-08-30T12:34:56Z",
               "level" => "info",
               "message" => "hello",
               "module" => "Elixir.Spore.Auth",
               "line" => 10,
               "pid" => inspect(self())
             }
    end

    test "metadata keys that are nil are omitted from the JSON" do
      out = JsonFormatter.format(:error, "boom", @ts, [])
      decoded = out |> IO.iodata_to_binary() |> Jason.decode!()

      assert decoded["time"] == "2026-08-30T12:34:56Z"
      assert decoded["message"] == "boom"
      assert decoded["pid"] == inspect(self())

      refute Map.has_key?(decoded, "module")
      refute Map.has_key?(decoded, "function")
      refute Map.has_key?(decoded, "line")
    end

    test "timestamps are zero padded and milliseconds dropped" do
      out = JsonFormatter.format(:info, "m", {{2026, 1, 2}, {3, 4, 5, 6}}, [])

      decoded = out |> IO.iodata_to_binary() |> Jason.decode!()
      assert decoded["time"] == "2026-01-02T03:04:05Z"
    end

    test "iodata messages are flattened into the JSON string" do
      out = JsonFormatter.format(:info, ["hel", ?l, "o"], @ts, [])
      decoded = out |> IO.iodata_to_binary() |> Jason.decode!()

      assert decoded["message"] == "hello"
    end

    test "level comes from the formatter level argument" do
      out = JsonFormatter.format(:warning, "m", @ts, [])

      decoded = out |> IO.iodata_to_binary() |> Jason.decode!()
      assert decoded["level"] == "warning"
    end

    test "non-iodata messages fall back to inspect instead of raising" do
      out = JsonFormatter.format(:info, {:weird, :message}, @ts, [])
      decoded = out |> IO.iodata_to_binary() |> Jason.decode!()

      assert decoded["message"] == "{:weird, :message}"
    end
  end
end
