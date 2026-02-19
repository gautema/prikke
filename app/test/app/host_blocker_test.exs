defmodule Prikke.HostBlockerTest do
  use ExUnit.Case, async: false

  alias Prikke.HostBlocker

  setup do
    # Each test gets a unique org_id to avoid interference
    org_id = Ecto.UUID.generate()
    %{org_id: org_id}
  end

  describe "block/4 and blocked?/2" do
    test "blocks a host for the specified duration", %{org_id: org_id} do
      HostBlocker.block(org_id, "api.example.com", 5_000, :rate_limited)

      assert HostBlocker.blocked?(org_id, "api.example.com")
    end

    test "different orgs have independent blocks", %{org_id: org_id} do
      other_org = Ecto.UUID.generate()

      HostBlocker.block(org_id, "api.example.com", 5_000, :rate_limited)

      assert HostBlocker.blocked?(org_id, "api.example.com")
      refute HostBlocker.blocked?(other_org, "api.example.com")
    end

    test "different hosts have independent blocks", %{org_id: org_id} do
      HostBlocker.block(org_id, "api.example.com", 5_000, :rate_limited)

      assert HostBlocker.blocked?(org_id, "api.example.com")
      refute HostBlocker.blocked?(org_id, "other.example.com")
    end

    test "expired block returns false", %{org_id: org_id} do
      # Block for 1ms — will expire immediately
      HostBlocker.block(org_id, "api.example.com", 1, :rate_limited)
      Process.sleep(5)

      refute HostBlocker.blocked?(org_id, "api.example.com")
    end

    test "unblocked host returns false", %{org_id: org_id} do
      refute HostBlocker.blocked?(org_id, "api.example.com")
    end
  end

  describe "blocked_until/2" do
    test "returns DateTime when blocked", %{org_id: org_id} do
      HostBlocker.block(org_id, "api.example.com", 60_000, :rate_limited)

      result = HostBlocker.blocked_until(org_id, "api.example.com")
      assert %DateTime{} = result
      assert DateTime.compare(result, DateTime.utc_now()) == :gt
    end

    test "returns nil when not blocked", %{org_id: org_id} do
      assert is_nil(HostBlocker.blocked_until(org_id, "api.example.com"))
    end

    test "returns nil when block has expired", %{org_id: org_id} do
      HostBlocker.block(org_id, "api.example.com", 1, :rate_limited)
      Process.sleep(5)

      assert is_nil(HostBlocker.blocked_until(org_id, "api.example.com"))
    end
  end

  describe "record_failure/2" do
    test "does not block after fewer than 3 failures", %{org_id: org_id} do
      HostBlocker.record_failure(org_id, "api.example.com")
      HostBlocker.record_failure(org_id, "api.example.com")

      refute HostBlocker.blocked?(org_id, "api.example.com")
    end

    test "blocks after 3 consecutive failures", %{org_id: org_id} do
      HostBlocker.record_failure(org_id, "api.example.com")
      HostBlocker.record_failure(org_id, "api.example.com")
      HostBlocker.record_failure(org_id, "api.example.com")

      assert HostBlocker.blocked?(org_id, "api.example.com")
    end

    test "escalates backoff duration on repeated blocks", %{org_id: org_id} do
      # First block: 30s backoff (3 failures)
      for _ <- 1..3, do: HostBlocker.record_failure(org_id, "api.example.com")

      first_until = HostBlocker.blocked_until(org_id, "api.example.com")
      assert %DateTime{} = first_until

      # Clear block to test next escalation
      :ets.delete(:blocked_hosts, {org_id, "api.example.com"})

      # More failures trigger next escalation level (60s)
      for _ <- 1..3, do: HostBlocker.record_failure(org_id, "api.example.com")

      second_until = HostBlocker.blocked_until(org_id, "api.example.com")
      assert %DateTime{} = second_until

      # Second block should be longer than first
      assert DateTime.compare(second_until, first_until) == :gt
    end
  end

  describe "record_success/2" do
    test "resets failure counter", %{org_id: org_id} do
      # Two failures, then success resets
      HostBlocker.record_failure(org_id, "api.example.com")
      HostBlocker.record_failure(org_id, "api.example.com")
      HostBlocker.record_success(org_id, "api.example.com")

      # One more failure should NOT trigger block (counter was reset)
      HostBlocker.record_failure(org_id, "api.example.com")

      refute HostBlocker.blocked?(org_id, "api.example.com")
    end
  end

  describe "block_rate_limited/3" do
    test "blocks with specified retry-after duration", %{org_id: org_id} do
      HostBlocker.block_rate_limited(org_id, "api.example.com", 120_000)

      assert HostBlocker.blocked?(org_id, "api.example.com")
      blocked_until = HostBlocker.blocked_until(org_id, "api.example.com")
      diff_ms = DateTime.diff(blocked_until, DateTime.utc_now(), :millisecond)
      # Should be roughly 120s (within 5s tolerance)
      assert diff_ms > 115_000
      assert diff_ms <= 120_000
    end

    test "uses default duration when retry-after is nil", %{org_id: org_id} do
      HostBlocker.block_rate_limited(org_id, "api.example.com", nil)

      assert HostBlocker.blocked?(org_id, "api.example.com")
      blocked_until = HostBlocker.blocked_until(org_id, "api.example.com")
      diff_ms = DateTime.diff(blocked_until, DateTime.utc_now(), :millisecond)
      default = HostBlocker.default_429_duration_ms()
      assert diff_ms > default - 5_000
      assert diff_ms <= default
    end
  end
end
