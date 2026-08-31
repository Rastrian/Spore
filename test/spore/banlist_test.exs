defmodule Spore.BanlistTest do
  @moduledoc """
  Unit tests for `Spore.Banlist`, the per-IP auth failure tracker.

  Documents the *actual* flip point: `note_failure/1` compares
  `prior_failures + 1 >= threshold`, so with the default threshold of 5 the
  **5th** `note_failure/1` is the one that triggers the ban (4 failures never
  ban). `auth_fail_threshold` and `auth_ban_ms` are read per call, but they are
  always paired with `on_exit/1` cleanup so no test leaks env.
  """

  use ExUnit.Case, async: false

  @ip1 {127, 0, 0, 1}
  @ip2 {10, 1, 2, 3}

  setup do
    Application.stop(:spore)
    start_supervised!(Spore.Banlist)
    :ok
  end

  describe "with the default configuration" do
    test "allow?/1 is true initially" do
      assert Spore.Banlist.allow?(@ip1)
    end

    test "the ban flips on the 5th note_failure/1 (prior failures + 1 >= threshold)" do
      assert Spore.Banlist.allow?(@ip1)

      # Find empirically at which failure count allow?/1 flips to false.
      ban_at =
        Enum.find_value(1..10, fn n ->
          Spore.Banlist.note_failure(@ip1)
          if Spore.Banlist.allow?(@ip1), do: nil, else: n
        end)

      # Actual behavior: the failure counter starts at 0 and the ban happens
      # when count + 1 >= threshold (default 5), i.e. on the 5th failure.
      assert ban_at == 5
    end

    test "failures below the threshold never ban" do
      Enum.each(1..4, fn _ -> Spore.Banlist.note_failure(@ip1) end)

      assert Spore.Banlist.allow?(@ip1)
    end

    test "bans are per ip" do
      Enum.each(1..5, fn _ -> Spore.Banlist.note_failure(@ip1) end)

      refute Spore.Banlist.allow?(@ip1)
      assert Spore.Banlist.allow?(@ip2)
    end
  end

  describe "with a short auth_ban_ms" do
    setup do
      Application.put_env(:spore, :auth_ban_ms, 50)
      on_exit(fn -> Application.delete_env(:spore, :auth_ban_ms) end)
      :ok
    end

    test "a ban expires after auth_ban_ms and the entry is cleaned up" do
      ban!(@ip1)

      refute Spore.Banlist.allow?(@ip1)

      Process.sleep(80)

      assert Spore.Banlist.allow?(@ip1)

      # The expired entry was deleted by the call above, so allow?/1 stays
      # true instead of re-evaluating a stale ban.
      assert Spore.Banlist.allow?(@ip1)
    end

    test "one more failure after expiry re-bans immediately (count is never reset)" do
      ban!(@ip1)

      Process.sleep(80)

      assert Spore.Banlist.allow?(@ip1)

      # Actual behavior: the {:count, ip} entry survives the expired ban, so a
      # single new failure is enough to hit the threshold again.
      :ok = Spore.Banlist.note_failure(@ip1)

      refute Spore.Banlist.allow?(@ip1)
    end
  end

  describe "with a higher auth_fail_threshold" do
    test "failures below threshold never ban" do
      Application.put_env(:spore, :auth_fail_threshold, 10)
      on_exit(fn -> Application.delete_env(:spore, :auth_fail_threshold) end)

      Enum.each(1..9, fn _ -> Spore.Banlist.note_failure(@ip1) end)

      assert Spore.Banlist.allow?(@ip1)

      :ok = Spore.Banlist.note_failure(@ip1)

      refute Spore.Banlist.allow?(@ip1)
    end
  end

  defp ban!(ip) do
    Enum.each(1..5, fn _ -> Spore.Banlist.note_failure(ip) end)
    refute Spore.Banlist.allow?(ip), "expected #{inspect(ip)} to be banned after 5 failures"
  end
end
