defmodule Spore.SecretQuotaTest do
  @moduledoc """
  Unit tests for `Spore.SecretQuota`, the per-secret tunnel limiter.

  Quotas are read from application env (`:spore, :secret_quotas`) **at init**,
  so tests pass their quota map via the `:quotas` tag: setup applies it before
  `start_supervised!/1` runs and always deletes it again via `on_exit/1`.
  """

  use ExUnit.Case, async: false

  @id "secret-a"
  @other "secret-b"

  setup context do
    Application.stop(:spore)

    if quotas = context[:quotas] do
      Application.put_env(:spore, :secret_quotas, quotas)
      on_exit(fn -> Application.delete_env(:spore, :secret_quotas) end)
    end

    start_supervised!(Spore.SecretQuota)
    :ok
  end

  describe "without any quota configured" do
    test "allow?/1 is always true and counts still increment" do
      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.allow?(@other)

      assert Spore.SecretQuota.snapshot_counts() == %{@id => 2, @other => 1}
    end

    test "many allow?/1 calls in a row stay allowed" do
      assert Enum.all?(1..10, fn _ -> Spore.SecretQuota.allow?(@id) end)

      assert Spore.SecretQuota.snapshot_counts() == %{@id => 10}
    end
  end

  describe "with a quota of 2" do
    @tag quotas: %{@id => 2}
    test "the first two allow?/1 are allowed and the third is rejected" do
      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.allow?(@id)
      refute Spore.SecretQuota.allow?(@id)
    end

    @tag quotas: %{@id => 2}
    test "a rejected allow?/1 does not increment the count" do
      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.snapshot_counts() == %{@id => 2}

      refute Spore.SecretQuota.allow?(@id)

      assert Spore.SecretQuota.snapshot_counts() == %{@id => 2},
             "a rejected allow? must not increment the count"
    end

    @tag quotas: %{@id => 2}
    test "dec/1 frees a slot" do
      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.allow?(@id)

      :ok = Spore.SecretQuota.dec(@id)

      assert Spore.SecretQuota.snapshot_counts() == %{@id => 1}
      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.snapshot_counts() == %{@id => 2}
    end

    @tag quotas: %{@id => 2}
    test "dec/1 down to zero removes the id from snapshot_counts/0" do
      assert Spore.SecretQuota.allow?(@id)

      :ok = Spore.SecretQuota.dec(@id)

      assert Spore.SecretQuota.snapshot_counts() == %{},
             "the id must be deleted, not left as nil or 0"
    end

    @tag quotas: %{@id => 2}
    test "dec/1 of an unknown id is a no-op" do
      assert Spore.SecretQuota.allow?(@id)

      :ok = Spore.SecretQuota.dec(@other)

      assert Spore.SecretQuota.snapshot_counts() == %{@id => 1}
    end

    @tag quotas: %{@id => 1, @other => 1}
    test "quotas are enforced per id" do
      assert Spore.SecretQuota.allow?(@id)
      refute Spore.SecretQuota.allow?(@id)

      assert Spore.SecretQuota.allow?(@other)
      refute Spore.SecretQuota.allow?(@other)
    end
  end

  describe "reload_limits/0" do
    @tag quotas: %{@id => 1}
    test "picks up a new quota map from the application env" do
      assert Spore.SecretQuota.allow?(@id)
      refute Spore.SecretQuota.allow?(@id)

      Application.put_env(:spore, :secret_quotas, %{@id => 5})
      on_exit(fn -> Application.delete_env(:spore, :secret_quotas) end)

      :ok = Spore.SecretQuota.reload_limits()

      assert Spore.SecretQuota.allow?(@id)
      assert Spore.SecretQuota.snapshot_counts() == %{@id => 2}
    end
  end
end
