defmodule Spore.ActiveTest do
  @moduledoc """
  Unit tests for `Spore.Active`, the active-tunnel counter.

  `max_active` is read per call from application env; env set in tests is
  always paired with `on_exit/1` cleanup.
  """

  use ExUnit.Case, async: false

  setup do
    Application.stop(:spore)
    start_supervised!(Spore.Active)
    :ok
  end

  describe "without max_active configured" do
    test "allow?/0 is always true and snapshot/0 increments" do
      assert Spore.Active.allow?()
      assert Spore.Active.snapshot() == 1

      assert Spore.Active.allow?()
      assert Spore.Active.allow?()
      assert Spore.Active.snapshot() == 3
    end

    test "dec/0 decrements the counter" do
      assert Spore.Active.allow?()
      assert Spore.Active.allow?()

      :ok = Spore.Active.dec()

      assert Spore.Active.snapshot() == 1
    end

    test "dec/0 below zero clamps at zero" do
      assert Spore.Active.allow?()

      :ok = Spore.Active.dec()
      :ok = Spore.Active.dec()
      :ok = Spore.Active.dec()

      assert Spore.Active.snapshot() == 0
      assert Spore.Active.snapshot() >= 0, "snapshot must never go negative"
    end
  end

  describe "with max_active: 2" do
    setup do
      Application.put_env(:spore, :max_active, 2)
      on_exit(fn -> Application.delete_env(:spore, :max_active) end)
      :ok
    end

    test "the first two allow?/0 are allowed, the third is rejected" do
      assert Spore.Active.allow?()
      assert Spore.Active.allow?()
      refute Spore.Active.allow?()

      # A rejected allow? must not bump the counter.
      assert Spore.Active.snapshot() == 2
    end

    test "after dec/0 a slot is free again" do
      assert Spore.Active.allow?()
      assert Spore.Active.allow?()
      refute Spore.Active.allow?()

      :ok = Spore.Active.dec()

      assert Spore.Active.snapshot() == 1
      assert Spore.Active.allow?()
      assert Spore.Active.snapshot() == 2
    end
  end
end
