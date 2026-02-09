defmodule PrikkeWeb.CreemWebhookController do
  use PrikkeWeb, :controller

  alias Prikke.Accounts
  alias Prikke.Audit
  alias Prikke.Billing.Creem

  require Logger

  def handle(conn, _params) do
    raw_body = PrikkeWeb.CacheBodyReader.get_raw_body(conn)
    signature = get_signature(conn)

    case Creem.verify_webhook_signature(raw_body, signature) do
      :ok ->
        process_event(conn, conn.body_params)

      :error ->
        Logger.warning("Invalid Creem webhook signature")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid signature"})
    end
  end

  defp process_event(conn, %{"eventType" => "checkout.completed"} = payload) do
    object = payload["object"]
    org_id = get_in(object, ["metadata", "organization_id"])
    customer_id = get_in(object, ["customer", "id"])
    subscription_id = get_in(object, ["subscription", "id"])

    if org_id && customer_id && subscription_id do
      case Accounts.activate_subscription(org_id, customer_id, subscription_id) do
        {:ok, org} ->
          Audit.log_system(:subscription_activated, :organization, org.id,
            organization_id: org.id,
            changes: %{"tier" => %{"from" => "free", "to" => "pro"}}
          )

        {:error, reason} ->
          Logger.error("Failed to activate subscription: #{inspect(reason)}")
      end
    else
      Logger.error("checkout.completed missing fields: org=#{inspect(org_id)} cust=#{inspect(customer_id)} sub=#{inspect(subscription_id)}")
    end

    json(conn, %{received: true})
  end

  defp process_event(conn, %{"eventType" => event_type} = payload)
       when event_type in [
              "subscription.active",
              "subscription.paid",
              "subscription.canceled",
              "subscription.scheduled_cancel",
              "subscription.expired",
              "subscription.past_due",
              "subscription.paused"
            ] do
    subscription_id = get_in(payload, ["object", "id"])
    status = event_type_to_status(event_type)

    # Also extract org_id from metadata as fallback — subscription events
    # can arrive before checkout.completed, so the subscription may not
    # be stored yet. In that case, activate via metadata.
    org_id = get_in(payload, ["object", "metadata", "organization_id"])
    customer_id = get_in(payload, ["object", "customer", "id"])

    if subscription_id do
      case Accounts.update_subscription_status(subscription_id, status) do
        {:ok, org} ->
          Audit.log_system(:subscription_status_changed, :organization, org.id,
            organization_id: org.id,
            changes: %{"subscription_status" => status}
          )

        {:error, :not_found} when not is_nil(org_id) and not is_nil(customer_id) ->
          # Race condition: subscription event arrived before checkout.completed
          Logger.info("Subscription not found, activating via metadata: org=#{org_id}")

          case Accounts.activate_subscription(org_id, customer_id, subscription_id) do
            {:ok, org} ->
              Audit.log_system(:subscription_activated, :organization, org.id,
                organization_id: org.id,
                changes: %{"tier" => %{"from" => "free", "to" => "pro"}}
              )

            {:error, reason} ->
              Logger.error("Failed to activate via fallback: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("Failed to update subscription status: #{inspect(reason)}")
      end
    end

    json(conn, %{received: true})
  end

  defp process_event(conn, %{"eventType" => event_type}) do
    Logger.info("Ignoring unhandled Creem event: #{event_type}")
    json(conn, %{received: true})
  end

  defp process_event(conn, _payload) do
    json(conn, %{received: true})
  end

  defp event_type_to_status("subscription.active"), do: "active"
  defp event_type_to_status("subscription.paid"), do: "active"
  defp event_type_to_status("subscription.canceled"), do: "canceled"
  defp event_type_to_status("subscription.scheduled_cancel"), do: "scheduled_cancel"
  defp event_type_to_status("subscription.expired"), do: "expired"
  defp event_type_to_status("subscription.past_due"), do: "past_due"
  defp event_type_to_status("subscription.paused"), do: "paused"

  defp get_signature(conn) do
    conn
    |> Plug.Conn.get_req_header("creem-signature")
    |> List.first("")
  end
end
