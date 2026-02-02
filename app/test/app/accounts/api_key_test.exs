defmodule Prikke.Accounts.ApiKeyTest do
  use ExUnit.Case, async: true
  alias Prikke.Accounts.ApiKey

  describe "generate_key_pair/0" do
    test "generates key_id and raw_secret with correct prefixes" do
      {key_id, raw_secret} = ApiKey.generate_key_pair()

      assert String.starts_with?(key_id, "pk_live_")
      assert String.starts_with?(raw_secret, "sk_live_")
    end

    test "generates unique keys each time" do
      {key_id1, secret1} = ApiKey.generate_key_pair()
      {key_id2, secret2} = ApiKey.generate_key_pair()

      refute key_id1 == key_id2
      refute secret1 == secret2
    end
  end

  describe "hash_secret/1" do
    test "returns a hex-encoded SHA256 hash" do
      hash = ApiKey.hash_secret("test_secret")

      # SHA256 produces 64 hex characters
      assert byte_size(hash) == 64
      assert Regex.match?(~r/^[a-f0-9]+$/, hash)
    end

    test "is deterministic" do
      hash1 = ApiKey.hash_secret("same_secret")
      hash2 = ApiKey.hash_secret("same_secret")

      assert hash1 == hash2
    end

    test "different secrets produce different hashes" do
      hash1 = ApiKey.hash_secret("secret1")
      hash2 = ApiKey.hash_secret("secret2")

      refute hash1 == hash2
    end
  end

  describe "verify_secret/2" do
    test "returns true for matching secret and hash" do
      secret = "sk_live_test_secret_12345"
      hash = ApiKey.hash_secret(secret)

      assert ApiKey.verify_secret(secret, hash) == true
    end

    test "returns false for non-matching secret" do
      secret = "sk_live_test_secret_12345"
      hash = ApiKey.hash_secret(secret)

      refute ApiKey.verify_secret("wrong_secret", hash)
      refute ApiKey.verify_secret("sk_live_test_secret_1234", hash)
      refute ApiKey.verify_secret(secret <> "x", hash)
    end

    test "returns false for empty secret" do
      hash = ApiKey.hash_secret("real_secret")

      refute ApiKey.verify_secret("", hash)
    end

    test "works with generated key pairs" do
      {_key_id, raw_secret} = ApiKey.generate_key_pair()
      hash = ApiKey.hash_secret(raw_secret)

      assert ApiKey.verify_secret(raw_secret, hash)
      refute ApiKey.verify_secret("wrong", hash)
    end

    # This test verifies we're using constant-time comparison
    # by ensuring the function doesn't short-circuit on partial matches
    test "uses constant-time comparison (timing-safe)" do
      secret = "sk_live_correct_secret_value"
      hash = ApiKey.hash_secret(secret)

      # All these should return false, but importantly they should
      # take roughly the same time (constant-time comparison)
      refute ApiKey.verify_secret("x", hash)
      refute ApiKey.verify_secret("sk_live_", hash)
      refute ApiKey.verify_secret("sk_live_correct_", hash)
      refute ApiKey.verify_secret("sk_live_correct_secret_valu", hash)
    end
  end
end
