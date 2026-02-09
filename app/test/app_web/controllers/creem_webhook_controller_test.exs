defmodule PrikkeWeb.CreemWebhookControllerTest do
  use PrikkeWeb.ConnCase, async: true

  alias Prikke.Accounts
  alias Prikke.Billing.Creem

  import Prikke.AccountsFixtures

  defp sign_payload(body) do
    secret = Application.get_env(:app, Creem)[:webhook_secret]

    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  defp post_webhook(conn, body) do
    signature = sign_payload(body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("creem-signature", signature)
    |> post(~p"/webhooks/creem", body)
  end

  describe "checkout.completed" do
    test "activates subscription for organization", %{conn: conn} do
      org = organization_fixture()
      assert org.tier == "free"

      body =
        Jason.encode!(%{
          eventType: "checkout.completed",
          object: %{
            id: "ch_test_123",
            customer: %{id: "cus_test_123", email: "test@example.com"},
            subscription: %{id: "sub_test_456"},
            metadata: %{organization_id: org.id}
          }
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "pro"
      assert updated.creem_customer_id == "cus_test_123"
      assert updated.creem_subscription_id == "sub_test_456"
      assert updated.subscription_status == "active"
    end

    test "stores billing_period and current_period_end from webhook", %{conn: conn} do
      org = organization_fixture()

      body =
        Jason.encode!(%{
          eventType: "checkout.completed",
          object: %{
            id: "ch_test_yearly",
            customer: %{id: "cus_test_yearly", email: "test@example.com"},
            subscription: %{
              id: "sub_test_yearly",
              current_period_end_date: "2027-02-09T12:00:00.000Z"
            },
            metadata: %{organization_id: org.id, billing_period: "yearly"}
          }
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "pro"
      assert updated.billing_period == "yearly"
      assert updated.current_period_end == ~U[2027-02-09 12:00:00Z]
    end

    test "defaults billing_period to monthly when not in metadata", %{conn: conn} do
      org = organization_fixture()

      body =
        Jason.encode!(%{
          eventType: "checkout.completed",
          object: %{
            id: "ch_test_default",
            customer: %{id: "cus_test_default", email: "test@example.com"},
            subscription: %{id: "sub_test_default"},
            metadata: %{organization_id: org.id}
          }
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.billing_period == "monthly"
    end

    test "handles missing metadata gracefully", %{conn: conn} do
      body =
        Jason.encode!(%{
          eventType: "checkout.completed",
          object: %{
            id: "ch_test_123",
            customer: %{id: "cus_test_123"},
            subscription: %{id: "sub_test_456"}
          }
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true
    end
  end

  describe "subscription events" do
    setup do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_sub", "sub_events_test")
      %{org: org}
    end

    test "subscription.canceled downgrades to free", %{conn: conn, org: org} do
      body =
        Jason.encode!(%{
          eventType: "subscription.canceled",
          object: %{id: "sub_events_test"}
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "free"
      assert updated.subscription_status == "canceled"
    end

    test "subscription.past_due keeps pro", %{conn: conn, org: org} do
      body =
        Jason.encode!(%{
          eventType: "subscription.past_due",
          object: %{id: "sub_events_test"}
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "pro"
      assert updated.subscription_status == "past_due"
    end

    test "subscription.scheduled_cancel keeps pro", %{conn: conn, org: org} do
      body =
        Jason.encode!(%{
          eventType: "subscription.scheduled_cancel",
          object: %{id: "sub_events_test"}
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "pro"
      assert updated.subscription_status == "scheduled_cancel"
    end

    test "subscription.expired downgrades to free", %{conn: conn, org: org} do
      body =
        Jason.encode!(%{
          eventType: "subscription.expired",
          object: %{id: "sub_events_test"}
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "free"
      assert updated.subscription_status == "expired"
    end

    test "subscription.active sets active status", %{conn: conn, org: org} do
      body =
        Jason.encode!(%{
          eventType: "subscription.active",
          object: %{id: "sub_events_test"}
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "pro"
      assert updated.subscription_status == "active"
    end

    test "subscription.paused keeps pro", %{conn: conn, org: org} do
      body =
        Jason.encode!(%{
          eventType: "subscription.paused",
          object: %{id: "sub_events_test"}
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "pro"
      assert updated.subscription_status == "paused"
    end
  end

  describe "subscription event race condition" do
    test "activates org via metadata when subscription not yet stored", %{conn: conn} do
      org = organization_fixture()
      assert org.tier == "free"

      # subscription.paid arrives before checkout.completed — subscription not stored yet
      body =
        Jason.encode!(%{
          eventType: "subscription.paid",
          object: %{
            id: "sub_race_test",
            customer: %{id: "cus_race_123"},
            metadata: %{organization_id: org.id}
          }
        })

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true

      updated = Accounts.get_organization(org.id)
      assert updated.tier == "pro"
      assert updated.creem_subscription_id == "sub_race_test"
      assert updated.creem_customer_id == "cus_race_123"
    end
  end

  describe "signature verification" do
    test "rejects requests with invalid signature", %{conn: conn} do
      body = Jason.encode!(%{eventType: "checkout.completed", object: %{}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("creem-signature", "invalidsig")
        |> post(~p"/webhooks/creem", body)

      assert json_response(conn, 401)["error"] == "Invalid signature"
    end

    test "rejects requests with missing signature", %{conn: conn} do
      body = Jason.encode!(%{eventType: "checkout.completed", object: %{}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/creem", body)

      assert json_response(conn, 401)["error"] == "Invalid signature"
    end
  end

  describe "unknown events" do
    test "returns 200 for unknown event types", %{conn: conn} do
      body = Jason.encode!(%{eventType: "unknown.event", object: %{}})

      conn = post_webhook(conn, body)
      assert json_response(conn, 200)["received"] == true
    end
  end
end
