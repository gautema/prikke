defmodule Prikke.Billing.CreemTest do
  use Prikke.DataCase, async: true

  alias Prikke.Billing.Creem

  describe "verify_webhook_signature/2" do
    test "returns :ok for a valid signature" do
      secret = Application.get_env(:app, Creem)[:webhook_secret]
      body = ~s({"eventType":"checkout.completed","object":{}})

      signature =
        :crypto.mac(:hmac, :sha256, secret, body)
        |> Base.encode16(case: :lower)

      assert :ok = Creem.verify_webhook_signature(body, signature)
    end

    test "returns :error for an invalid signature" do
      body = ~s({"eventType":"checkout.completed","object":{}})
      assert :error = Creem.verify_webhook_signature(body, "invalidsignature")
    end

    test "returns :error for empty signature" do
      body = ~s({"eventType":"checkout.completed","object":{}})
      assert :error = Creem.verify_webhook_signature(body, "")
    end

    test "returns :error for nil inputs" do
      assert :error = Creem.verify_webhook_signature(nil, nil)
    end

    test "handles uppercase signature" do
      secret = Application.get_env(:app, Creem)[:webhook_secret]
      body = ~s({"test":"data"})

      signature =
        :crypto.mac(:hmac, :sha256, secret, body)
        |> Base.encode16(case: :upper)

      assert :ok = Creem.verify_webhook_signature(body, signature)
    end
  end
end
