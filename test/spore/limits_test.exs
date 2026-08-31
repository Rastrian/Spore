defmodule Spore.LimitsTest do
  @moduledoc """
  Unit tests for `Spore.Limits`, the per-IP connection limiter.

  `mix test` boots the whole application tree, which already registers the
  `Spore.Limits` name, so every test stops the app first and then starts a
  fresh, isolated instance under ExUnit's supervision.
  """

  use ExUnit.Case, async: false

  @ip1 {127, 0, 0, 1}
  @ip2 {192, 168, 0, 2}

  setup do
    Application.stop(:spore)
    start_supervised!(Spore.Limits)
    :ok
  end

  describe "without max_conns_per_ip configured" do
    test "can_open?/1 allows any number of connections" do
      assert Enum.all?(1..25, fn _ -> Spore.Limits.can_open?(@ip1) end)
    end

    test "every allowed can_open?/1 is counted in snapshot/0" do
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip1)

      assert Spore.Limits.snapshot() == %{@ip1 => 3}
    end
  end

  describe "with max_conns_per_ip: 2" do
    setup do
      put_max_conns_per_ip(2)
      :ok
    end

    test "the first two can_open?/1 are allowed and the third is rejected" do
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip1)
      refute Spore.Limits.can_open?(@ip1)
    end

    test "a rejected can_open?/1 does not bump the counter (state is rolled back)" do
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.snapshot() == %{@ip1 => 2}

      refute Spore.Limits.can_open?(@ip1)

      assert Spore.Limits.snapshot() == %{@ip1 => 2},
             "a rejected can_open? must not change the snapshot"
    end

    test "close/1 frees a slot so can_open?/1 is allowed again" do
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip1)
      refute Spore.Limits.can_open?(@ip1)

      :ok = Spore.Limits.close(@ip1)

      assert Spore.Limits.snapshot() == %{@ip1 => 1}
      assert Spore.Limits.can_open?(@ip1)
    end

    test "close/1 down to zero removes the ip from snapshot/0" do
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip1)

      :ok = Spore.Limits.close(@ip1)
      assert Spore.Limits.snapshot() == %{@ip1 => 1}

      :ok = Spore.Limits.close(@ip1)

      assert Spore.Limits.snapshot() == %{},
             "the key must be deleted, not left as nil or 0"
    end

    test "close/1 of an unknown ip is a no-op" do
      assert Spore.Limits.can_open?(@ip1)

      :ok = Spore.Limits.close(@ip2)

      assert Spore.Limits.snapshot() == %{@ip1 => 1}
    end

    test "different ips have independent counters" do
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip2)

      assert Spore.Limits.snapshot() == %{@ip1 => 2, @ip2 => 1}

      # @ip1 is at its limit while @ip2 still has room.
      refute Spore.Limits.can_open?(@ip1)
      assert Spore.Limits.can_open?(@ip2)
      refute Spore.Limits.can_open?(@ip2)

      assert Spore.Limits.snapshot() == %{@ip1 => 2, @ip2 => 2}
    end
  end

  defp put_max_conns_per_ip(n) do
    Application.put_env(:spore, :max_conns_per_ip, n)
    on_exit(fn -> Application.delete_env(:spore, :max_conns_per_ip) end)
  end
end
