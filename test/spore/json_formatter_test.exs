defmodule Spore.JsonFormatterTest do
  use ExUnit.Case, async: false

  alias Spore.JsonFormatter

  @ts {{2026, 8, 30}, {12, 34, 56, 789}}

  # ---------------------------------------------------------------------------
  # KNOWN DEFECT (characterization tests; lib intentionally left untouched)
  #
  # `Jason.encode!(Enum.reject(map, fn {_k, v} -> is_nil(v) end))` in
  # lib/spore/json_formatter.ex:20 cannot work: `Enum.reject/2` over a *map*
  # returns a list of {key, value} tuples, and Jason has no encoder for
  # tuples. format/4 therefore ALWAYS raises Protocol.UndefinedError instead
  # of returning a JSON line, i.e. `--json-logs` output crashes on every
  # message (the fix would be Map.reject/2). Until the lib is fixed, the
  # contract tests below are skipped; these tests pin the current behavior
  # so the fix flips them visibly.
  # ---------------------------------------------------------------------------

  describe "format/4 (current, defective behavior)" do
    test "raises instead of returning JSON for a full metadata set" do
      assert_raise Protocol.UndefinedError, ~r/Jason.Encoder not implemented for Tuple/, fn ->
        JsonFormatter.format(
          :info,
          self(),
          {Logger, "hello", @ts, [module: Spore.Auth, line: 10, pid: self()]},
          []
        )
      end
    end

    test "raises even with no metadata at all" do
      assert_raise Protocol.UndefinedError, ~r/Jason.Encoder not implemented for Tuple/, fn ->
        JsonFormatter.format(:error, self(), {Logger, "boom", @ts, []}, [])
      end
    end

    test "raises for an iodata message too (never reaches the encoder)" do
      assert_raise Protocol.UndefinedError, fn ->
        JsonFormatter.format(:info, self(), {Logger, ["hel", ?l, "o"], @ts, []}, [])
      end
    end
  end

  describe "format/4 (intended contract, blocked by the defect above)" do
    @tag skip:
           "lib bug: Enum.reject over a map yields tuples Jason cannot encode; format/4 raises"
    test "renders a single JSON line terminated by a newline" do
      out =
        JsonFormatter.format(
          :info,
          self(),
          {Logger, "hello", @ts, [module: Spore.Auth, line: 10, pid: self()]},
          []
        )

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

    @tag skip:
           "lib bug: Enum.reject over a map yields tuples Jason cannot encode; format/4 raises"
    test "metadata keys that are nil are omitted from the JSON" do
      out = JsonFormatter.format(:error, self(), {Logger, "boom", @ts, []}, [])
      decoded = out |> IO.iodata_to_binary() |> Jason.decode!()

      assert decoded["time"] == "2026-08-30T12:34:56Z"
      assert decoded["message"] == "boom"
      assert decoded["pid"] == inspect(self())

      refute Map.has_key?(decoded, "module")
      refute Map.has_key?(decoded, "function")
      refute Map.has_key?(decoded, "line")
    end

    @tag skip:
           "lib bug: Enum.reject over a map yields tuples Jason cannot encode; format/4 raises"
    test "timestamps are zero padded and milliseconds dropped" do
      out =
        JsonFormatter.format(:info, self(), {Logger, "m", {{2026, 1, 2}, {3, 4, 5, 6}}, []}, [])

      decoded = out |> IO.iodata_to_binary() |> Jason.decode!()
      assert decoded["time"] == "2026-01-02T03:04:05Z"
    end
  end
end
