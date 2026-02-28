defmodule Prikke.ApiKeyCacheTest do
  use Prikke.DataCase

  alias Prikke.ApiKeyCache
  alias Prikke.Accounts

  import Prikke.AccountsFixtures

  describe "lookup/1" do
    test "returns :miss for uncached key" do
      assert :miss = ApiKeyCache.lookup("pk_live_nonexistent")
    end

    test "returns cached data after put" do
      org = organization_fixture()

      ApiKeyCache.put("pk_live_test", "hash123", org, "My Key")

      assert {:ok, "hash123", ^org, "My Key"} = ApiKeyCache.lookup("pk_live_test")
    end
  end

  describe "invalidate/1" do
    test "removes a cached entry" do
      org = organization_fixture()

      ApiKeyCache.put("pk_live_del", "hash", org, "Key")
      assert {:ok, _, _, _} = ApiKeyCache.lookup("pk_live_del")

      ApiKeyCache.invalidate("pk_live_del")
      assert :miss = ApiKeyCache.lookup("pk_live_del")
    end
  end

  describe "invalidate_org/1" do
    test "removes all entries for an organization" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      ApiKeyCache.put("pk_live_org1a", "h1", org1, "K1")
      ApiKeyCache.put("pk_live_org1b", "h2", org1, "K2")
      ApiKeyCache.put("pk_live_org2a", "h3", org2, "K3")

      ApiKeyCache.invalidate_org(org1.id)

      assert :miss = ApiKeyCache.lookup("pk_live_org1a")
      assert :miss = ApiKeyCache.lookup("pk_live_org1b")
      assert {:ok, _, _, _} = ApiKeyCache.lookup("pk_live_org2a")
    end
  end

  describe "verify_api_key with cache" do
    test "caches API key on first lookup, serves from cache on second" do
      user = user_fixture()
      org = organization_fixture(user: user)

      {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user, %{name: "Test"})
      full_key = "#{api_key.key_id}.#{raw_secret}"

      # First call: cache miss, DB lookup
      assert {:ok, returned_org, "Test"} = Accounts.verify_api_key(full_key)
      assert returned_org.id == org.id

      # Should now be in cache
      assert {:ok, _, _, _} = ApiKeyCache.lookup(api_key.key_id)

      # Second call: cache hit
      assert {:ok, returned_org2, "Test"} = Accounts.verify_api_key(full_key)
      assert returned_org2.id == org.id
    end

    test "invalidates cache on API key deletion" do
      user = user_fixture()
      org = organization_fixture(user: user)

      {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user, %{name: "DelTest"})
      full_key = "#{api_key.key_id}.#{raw_secret}"

      # Populate cache
      assert {:ok, _, _} = Accounts.verify_api_key(full_key)
      assert {:ok, _, _, _} = ApiKeyCache.lookup(api_key.key_id)

      # Delete
      {:ok, _} = Accounts.delete_api_key(api_key)

      # Cache should be invalidated
      assert :miss = ApiKeyCache.lookup(api_key.key_id)
    end

    test "rejects invalid secret even from cache" do
      user = user_fixture()
      org = organization_fixture(user: user)

      {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user, %{name: "BadSecret"})
      full_key = "#{api_key.key_id}.#{raw_secret}"

      # Populate cache
      assert {:ok, _, _} = Accounts.verify_api_key(full_key)

      # Try with wrong secret
      bad_key = "#{api_key.key_id}.sk_live_wrong"
      assert {:error, :invalid_secret} = Accounts.verify_api_key(bad_key)
    end
  end
end
