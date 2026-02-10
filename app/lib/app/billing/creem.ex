defmodule Prikke.Billing.Creem do
  @moduledoc """
  Thin wrapper around the Creem API for payment processing.
  Creem is a Merchant of Record that handles VAT/tax.
  """

  require Logger

  @doc """
  Creates a checkout session for upgrading an organization to Pro.
  Returns `{:ok, checkout_url}` or `{:error, reason}`.
  """
  def create_checkout(org_id, email, success_url, billing_period \\ "monthly") do
    product_id =
      case billing_period do
        "yearly" -> config(:yearly_product_id)
        _ -> config(:monthly_product_id)
      end

    body = %{
      product_id: product_id,
      request_id: "org_#{org_id}_#{System.unique_integer([:positive])}",
      metadata: %{organization_id: org_id, billing_period: billing_period},
      customer: %{email: email},
      success_url: success_url
    }

    case post("/v1/checkouts", body) do
      {:ok, %{status: status, body: %{"checkout_url" => url}}} when status in 200..299 ->
        {:ok, url}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Creem checkout failed (#{status}): #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.error("Creem checkout request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Upgrades a subscription to a different product (e.g. monthly to yearly).
  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def upgrade_subscription(subscription_id, product_id) do
    body = %{
      product_id: product_id,
      update_behavior: "proration-charge-immediately"
    }

    case post("/v1/subscriptions/#{subscription_id}/upgrade", body) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Creem upgrade failed (#{status}): #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.error("Creem upgrade request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Cancels a subscription. Mode can be "scheduled" or "immediate".
  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def cancel_subscription(subscription_id, mode \\ "scheduled") do
    case post("/v1/subscriptions/#{subscription_id}/cancel", %{mode: mode}) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Creem cancel failed (#{status}): #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.error("Creem cancel request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the billing portal URL for a customer.
  Returns `{:ok, portal_url}` or `{:error, reason}`.
  """
  def get_billing_portal_url(customer_id) do
    case post("/v1/customers/billing", %{customer_id: customer_id}) do
      {:ok, %{status: status, body: %{"customer_portal_link" => url}}} when status in 200..299 ->
        {:ok, url}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Creem billing portal failed (#{status}): #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.error("Creem billing portal request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Verifies a Creem webhook signature.
  Returns `:ok` if valid, `:error` if invalid.
  """
  def verify_webhook_signature(raw_body, signature)
      when is_binary(raw_body) and is_binary(signature) do
    secret = config(:webhook_secret)

    expected =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      :error
    end
  end

  def verify_webhook_signature(_, _), do: :error

  # Private

  defp post(path, body) do
    url = "#{config(:base_url)}#{path}"

    Req.post(url,
      json: body,
      headers: [
        {"x-api-key", config(:api_key)},
        {"content-type", "application/json"}
      ]
    )
  end

  defp config(key) do
    Application.get_env(:app, __MODULE__)[key]
  end
end
