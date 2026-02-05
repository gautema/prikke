defmodule Prikke.IdempotencyTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures

  alias Prikke.Idempotency

  describe "get_cached_response/2" do
    test "returns :not_found when key does not exist" do
      org = organization_fixture()
      assert Idempotency.get_cached_response(org.id, "nonexistent") == :not_found
    end

    test "returns cached response when key exists" do
      org = organization_fixture()
      {:ok, _} = Idempotency.store_response(org.id, "test-key", 202, ~s({"data": "test"}))

      assert {:ok, cached} = Idempotency.get_cached_response(org.id, "test-key")
      assert cached.status_code == 202
      assert cached.response_body == ~s({"data": "test"})
      assert cached.organization_id == org.id
    end

    test "keys are scoped to organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, _} = Idempotency.store_response(org1.id, "shared-key", 200, "org1-response")

      assert {:ok, _} = Idempotency.get_cached_response(org1.id, "shared-key")
      assert Idempotency.get_cached_response(org2.id, "shared-key") == :not_found
    end
  end

  describe "store_response/4" do
    test "stores a response for new key" do
      org = organization_fixture()
      assert {:ok, key} = Idempotency.store_response(org.id, "new-key", 201, "created")
      assert key.key == "new-key"
      assert key.status_code == 201
    end

    test "handles duplicate key gracefully (on_conflict: :nothing)" do
      org = organization_fixture()
      {:ok, first} = Idempotency.store_response(org.id, "dup-key", 202, "first response")
      {:ok, _second} = Idempotency.store_response(org.id, "dup-key", 200, "second response")

      # Original response is preserved
      {:ok, cached} = Idempotency.get_cached_response(org.id, "dup-key")
      assert cached.id == first.id
      assert cached.response_body == "first response"
    end
  end

  describe "cleanup_expired_keys/1" do
    test "deletes keys older than TTL" do
      org = organization_fixture()
      {:ok, _} = Idempotency.store_response(org.id, "fresh-key", 200, "fresh")

      # Manually age a key by updating its inserted_at
      {:ok, old} = Idempotency.store_response(org.id, "old-key", 200, "old")

      old_time = DateTime.add(DateTime.utc_now(), -25, :hour)

      Prikke.Repo.update_all(
        from(k in Prikke.Idempotency.IdempotencyKey, where: k.id == ^old.id),
        set: [inserted_at: old_time]
      )

      {deleted, _} = Idempotency.cleanup_expired_keys(24)
      assert deleted == 1

      # Fresh key still exists
      assert {:ok, _} = Idempotency.get_cached_response(org.id, "fresh-key")
      # Old key is gone
      assert Idempotency.get_cached_response(org.id, "old-key") == :not_found
    end

    test "returns 0 when nothing to clean" do
      assert {0, _} = Idempotency.cleanup_expired_keys()
    end
  end
end
