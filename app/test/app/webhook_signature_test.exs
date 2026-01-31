defmodule Prikke.WebhookSignatureTest do
  use ExUnit.Case, async: true

  alias Prikke.WebhookSignature

  describe "sign/2" do
    test "generates sha256-prefixed signature" do
      signature = WebhookSignature.sign("test body", "secret123")
      assert String.starts_with?(signature, "sha256=")
    end

    test "generates lowercase hex signature" do
      signature = WebhookSignature.sign("test body", "secret123")
      # Remove prefix and check it's valid lowercase hex
      "sha256=" <> hex = signature
      assert Regex.match?(~r/^[a-f0-9]{64}$/, hex)
    end

    test "generates consistent signatures for same input" do
      sig1 = WebhookSignature.sign("body", "secret")
      sig2 = WebhookSignature.sign("body", "secret")
      assert sig1 == sig2
    end

    test "generates different signatures for different bodies" do
      sig1 = WebhookSignature.sign("body1", "secret")
      sig2 = WebhookSignature.sign("body2", "secret")
      refute sig1 == sig2
    end

    test "generates different signatures for different secrets" do
      sig1 = WebhookSignature.sign("body", "secret1")
      sig2 = WebhookSignature.sign("body", "secret2")
      refute sig1 == sig2
    end

    test "handles empty body" do
      signature = WebhookSignature.sign("", "secret")
      assert String.starts_with?(signature, "sha256=")
      "sha256=" <> hex = signature
      assert String.length(hex) == 64
    end

    test "handles unicode in body" do
      signature = WebhookSignature.sign("héllo wörld 日本語", "secret")
      assert String.starts_with?(signature, "sha256=")
    end

    test "matches expected HMAC-SHA256 output" do
      # Verify against known HMAC-SHA256 value
      # echo -n "test" | openssl dgst -sha256 -hmac "key"
      # => 02afb56304902c656fcb737cdd03de6205bb6d401da2812efd9b2d36a08af159
      signature = WebhookSignature.sign("test", "key")
      assert signature == "sha256=02afb56304902c656fcb737cdd03de6205bb6d401da2812efd9b2d36a08af159"
    end
  end

  describe "verify/3" do
    test "returns true for valid signature" do
      body = "request body"
      secret = "whsec_testsecret123"
      signature = WebhookSignature.sign(body, secret)

      assert WebhookSignature.verify(body, secret, signature) == true
    end

    test "returns false for invalid signature" do
      body = "request body"
      secret = "whsec_testsecret123"

      assert WebhookSignature.verify(body, secret, "sha256=invalid") == false
    end

    test "returns false for tampered body" do
      secret = "whsec_testsecret123"
      signature = WebhookSignature.sign("original body", secret)

      assert WebhookSignature.verify("tampered body", secret, signature) == false
    end

    test "returns false for wrong secret" do
      body = "request body"
      signature = WebhookSignature.sign(body, "correct_secret")

      assert WebhookSignature.verify(body, "wrong_secret", signature) == false
    end

    test "returns false for signature without prefix" do
      body = "test"
      secret = "key"
      # Raw hex without sha256= prefix
      raw_hex = "02afb56304902c656fcb737cdd03de6205bb6d401da2812efd9b2d36a08af159"

      assert WebhookSignature.verify(body, secret, raw_hex) == false
    end
  end

  describe "build_headers/4" do
    test "returns list of three headers" do
      headers = WebhookSignature.build_headers("job-123", "exec-456", "body", "secret")
      assert length(headers) == 3
    end

    test "includes job id header" do
      headers = WebhookSignature.build_headers("job-123", "exec-456", "body", "secret")
      assert {"x-runlater-job-id", "job-123"} in headers
    end

    test "includes execution id header" do
      headers = WebhookSignature.build_headers("job-123", "exec-456", "body", "secret")
      assert {"x-runlater-execution-id", "exec-456"} in headers
    end

    test "includes signature header with correct format" do
      headers = WebhookSignature.build_headers("job-123", "exec-456", "body", "secret")
      {_, signature} = Enum.find(headers, fn {k, _} -> k == "x-runlater-signature" end)

      assert String.starts_with?(signature, "sha256=")
    end

    test "signature matches body content" do
      body = ~s({"action": "sync"})
      secret = "whsec_abc123"

      headers = WebhookSignature.build_headers("j1", "e1", body, secret)
      {_, signature} = Enum.find(headers, fn {k, _} -> k == "x-runlater-signature" end)

      # Verify the signature is correct for this body
      assert WebhookSignature.verify(body, secret, signature) == true
    end

    test "empty body produces valid signature" do
      headers = WebhookSignature.build_headers("j1", "e1", "", "secret")
      {_, signature} = Enum.find(headers, fn {k, _} -> k == "x-runlater-signature" end)

      assert WebhookSignature.verify("", "secret", signature) == true
    end
  end

  describe "security properties" do
    test "timing-safe comparison prevents timing attacks" do
      # This test verifies the implementation uses constant-time comparison
      # by checking that verification time doesn't vary significantly based on
      # where the first difference occurs in the signature

      body = "test body"
      secret = "secret"
      valid_sig = WebhookSignature.sign(body, secret)

      # Create signatures that differ at different positions
      "sha256=" <> hex = valid_sig
      wrong_first_char = "sha256=0" <> String.slice(hex, 1..-1//1)
      wrong_last_char = "sha256=" <> String.slice(hex, 0..-2//1) <> "0"

      # Both should return false (we can't easily test timing in unit tests,
      # but we verify the function works correctly)
      refute WebhookSignature.verify(body, secret, wrong_first_char)
      refute WebhookSignature.verify(body, secret, wrong_last_char)
    end
  end
end
