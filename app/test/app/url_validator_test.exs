defmodule Prikke.UrlValidatorTest do
  use ExUnit.Case, async: true
  alias Prikke.UrlValidator

  describe "validate_webhook_url/1" do
    test "allows valid public HTTPS URLs" do
      assert :ok = UrlValidator.validate_webhook_url("https://example.com/webhook")
      assert :ok = UrlValidator.validate_webhook_url("https://api.example.com/hooks/123")
      assert :ok = UrlValidator.validate_webhook_url("https://hooks.slack.com/services/xxx")
    end

    test "allows valid public HTTP URLs" do
      assert :ok = UrlValidator.validate_webhook_url("http://example.com/webhook")
    end

    test "allows nil and empty strings" do
      assert :ok = UrlValidator.validate_webhook_url(nil)
      assert :ok = UrlValidator.validate_webhook_url("")
    end

    test "rejects non-HTTP/HTTPS schemes" do
      assert {:error, "must use HTTP or HTTPS"} = UrlValidator.validate_webhook_url("ftp://example.com")
      assert {:error, "must use HTTP or HTTPS"} = UrlValidator.validate_webhook_url("file:///etc/passwd")
      assert {:error, "must use HTTP or HTTPS"} = UrlValidator.validate_webhook_url("javascript:alert(1)")
    end

    test "rejects URLs without host" do
      assert {:error, "must have a valid host"} = UrlValidator.validate_webhook_url("http://")
      assert {:error, "must have a valid host"} = UrlValidator.validate_webhook_url("https:///path")
    end

    # SSRF protection tests
    test "rejects localhost" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://localhost/webhook")

      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://localhost:8080/webhook")

      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("https://localhost/webhook")
    end

    test "rejects 127.0.0.1 loopback" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://127.0.0.1/webhook")

      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://127.0.0.1:6379/")
    end

    test "rejects 10.x.x.x private range" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://10.0.0.1/webhook")

      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://10.255.255.255/webhook")
    end

    test "rejects 172.16-31.x.x private range" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://172.16.0.1/webhook")

      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://172.31.255.255/webhook")
    end

    test "rejects 192.168.x.x private range" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://192.168.0.1/webhook")

      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://192.168.1.100/webhook")
    end

    test "rejects AWS metadata endpoint (169.254.169.254)" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://169.254.169.254/latest/meta-data/")

      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://169.254.169.254/latest/api/token")
    end

    test "rejects .internal domains" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://service.internal/webhook")
    end

    test "rejects .local domains" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://myservice.local/webhook")
    end

    test "rejects .localhost domains" do
      assert {:error, "cannot target private or internal addresses"} =
               UrlValidator.validate_webhook_url("http://app.localhost/webhook")
    end
  end

  describe "private_host?/1" do
    test "returns true for localhost variants" do
      assert UrlValidator.private_host?("localhost")
      assert UrlValidator.private_host?("LOCALHOST")
      assert UrlValidator.private_host?("127.0.0.1")
    end

    test "returns true for private IP ranges as strings" do
      assert UrlValidator.private_host?("10.0.0.1")
      assert UrlValidator.private_host?("192.168.1.1")
      assert UrlValidator.private_host?("172.16.0.1")
    end

    test "returns true for cloud metadata IP" do
      assert UrlValidator.private_host?("169.254.169.254")
    end

    test "returns false for public hostnames" do
      refute UrlValidator.private_host?("example.com")
      refute UrlValidator.private_host?("api.github.com")
    end
  end
end
