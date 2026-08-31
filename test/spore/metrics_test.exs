defmodule Spore.MetricsTest do
  @moduledoc """
  Unit tests for `Spore.Metrics` (ETS-backed counters and Prometheus rendering).

  Both ETS tables (`:spore_metrics` / `:spore_accept_ts`) are created in
  `init/1`, so every test gets a fresh pair through `start_supervised!/1` (the
  tables of the previous test die with their owner). Counters created here are
  prefixed with `spore_test_` so they never clash with the real metric names.
  """

  use ExUnit.Case, async: false

  setup do
    Application.stop(:spore)
    start_supervised!(Spore.Metrics)
    :ok
  end

  describe "inc/2" do
    test "creates a counter at 1 and accumulates deltas" do
      Spore.Metrics.inc(:spore_test_counter)

      assert :ets.lookup(:spore_metrics, :spore_test_counter) == [{:spore_test_counter, 1}]

      Spore.Metrics.inc(:spore_test_counter, 5)

      assert :ets.lookup(:spore_metrics, :spore_test_counter) == [{:spore_test_counter, 6}]
    end
  end

  describe "track_bytes/1" do
    test "zero and negative byte counts leave the counter absent" do
      # Actual behavior: the n > 0 guard means non-positive values raise
      # FunctionClauseError instead of being silently ignored, and nothing is
      # written to ETS.
      assert_raise FunctionClauseError, fn -> Spore.Metrics.track_bytes(0) end
      assert_raise FunctionClauseError, fn -> Spore.Metrics.track_bytes(-1) end

      assert :ets.lookup(:spore_metrics, :spore_bytes_proxied_total) == []
    end

    test "adds byte counts to the counter" do
      Spore.Metrics.track_bytes(10)

      assert :ets.lookup(:spore_metrics, :spore_bytes_proxied_total) == [
               {:spore_bytes_proxied_total, 10}
             ]

      Spore.Metrics.track_bytes(5)

      assert :ets.lookup(:spore_metrics, :spore_bytes_proxied_total) == [
               {:spore_bytes_proxied_total, 15}
             ]
    end
  end

  describe "note_pending/1 and note_accept/1" do
    test "note_accept/1 records the acceptance, latency and cleans up its entry" do
      id = :spore_test_conn_1

      Spore.Metrics.note_pending(id)

      assert [{^id, ts}] = :ets.lookup(:spore_accept_ts, id)
      assert is_integer(ts)

      assert :ets.lookup(:spore_metrics, :spore_connections_incoming_total) == [
               {:spore_connections_incoming_total, 1}
             ]

      Spore.Metrics.note_accept(id)

      assert :ets.lookup(:spore_metrics, :spore_connections_accepted_total) == [
               {:spore_connections_accepted_total, 1}
             ]

      assert [{:spore_accept_latency_ms_sum, sum}] =
               :ets.lookup(:spore_metrics, :spore_accept_latency_ms_sum)

      assert is_integer(sum) and sum >= 0

      assert :ets.lookup(:spore_metrics, :spore_accept_latency_ms_count) == [
               {:spore_accept_latency_ms_count, 1}
             ]

      assert :ets.lookup(:spore_accept_ts, id) == [], "no leftover timestamp entry"
    end

    test "note_accept/1 of an unknown id is a no-op" do
      Spore.Metrics.note_accept(:spore_test_never_pended)

      assert :ets.lookup(:spore_metrics, :spore_connections_accepted_total) == []
      assert :ets.lookup(:spore_accept_ts, :spore_test_never_pended) == []
    end
  end

  describe "stale/0" do
    test "increments the stale connections counter" do
      Spore.Metrics.stale()

      assert :ets.lookup(:spore_metrics, :spore_connections_stale_total) == [
               {:spore_connections_stale_total, 1}
             ]

      Spore.Metrics.stale()

      assert :ets.lookup(:spore_metrics, :spore_connections_stale_total) == [
               {:spore_connections_stale_total, 2}
             ]
    end
  end

  describe "render/0" do
    test "emits TYPE lines, counter values and the gauge lines" do
      # render/0 also snapshots Limits/Active/SecretQuota and counts the
      # children of the pending DynamicSupervisor, so start those too.
      start_supervised!(
        {DynamicSupervisor, name: Spore.Pending.Supervisor, strategy: :one_for_one}
      )

      start_supervised!(Spore.Limits)
      start_supervised!(Spore.Active)
      start_supervised!(Spore.SecretQuota)

      Spore.Metrics.inc(:spore_test_render_counter, 7)

      out = Spore.Metrics.render()

      assert out =~ "# TYPE spore_test_render_counter counter"
      assert out =~ "spore_test_render_counter 7"
      assert out =~ "spore_pending_active 0"
      assert out =~ "spore_active_tunnels 0"
    end
  end
end
