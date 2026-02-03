defmodule Prikke.UrlValidator do
  @moduledoc """
  URL validation utilities for webhook URLs.
  Prevents SSRF attacks by blocking requests to private/internal addresses.
  """

  @doc """
  Validates that a URL is safe to make HTTP requests to.
  Returns :ok or {:error, reason}.

  Checks:
  - Must be HTTP or HTTPS
  - Must have a valid host
  - Host must not resolve to a private IP address
  """
  def validate_webhook_url(nil), do: :ok
  def validate_webhook_url(""), do: :ok

  def validate_webhook_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "must use HTTP or HTTPS"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "must have a valid host"}

      private_host?(uri.host) ->
        {:error, "cannot target private or internal addresses"}

      true ->
        :ok
    end
  end

  @doc """
  Checks if a host resolves to a private/internal IP address.
  This prevents SSRF attacks targeting internal services or cloud metadata endpoints.
  """
  def private_host?(host) when is_binary(host) do
    # Check for obviously private hostnames
    if obviously_private_hostname?(host) do
      true
    else
      # Try to resolve the hostname and check the IP
      case resolve_host(host) do
        {:ok, ip} -> private_ip?(ip)
        # If we can't resolve, allow it (DNS may not be available at validation time)
        # The actual request will fail later if the host is invalid
        :error -> false
      end
    end
  end

  # Common internal/private hostnames that should always be blocked
  defp obviously_private_hostname?(host) do
    host = String.downcase(host)

    host == "localhost" or
      host == "127.0.0.1" or
      String.starts_with?(host, "192.168.") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "172.16.") or
      String.starts_with?(host, "172.17.") or
      String.starts_with?(host, "172.18.") or
      String.starts_with?(host, "172.19.") or
      String.starts_with?(host, "172.20.") or
      String.starts_with?(host, "172.21.") or
      String.starts_with?(host, "172.22.") or
      String.starts_with?(host, "172.23.") or
      String.starts_with?(host, "172.24.") or
      String.starts_with?(host, "172.25.") or
      String.starts_with?(host, "172.26.") or
      String.starts_with?(host, "172.27.") or
      String.starts_with?(host, "172.28.") or
      String.starts_with?(host, "172.29.") or
      String.starts_with?(host, "172.30.") or
      String.starts_with?(host, "172.31.") or
      host == "169.254.169.254" or
      String.ends_with?(host, ".internal") or
      String.ends_with?(host, ".local") or
      String.ends_with?(host, ".localhost")
  end

  defp resolve_host(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  # Check if an IP address is in a private/reserved range
  # RFC 1918 private ranges + other reserved ranges
  # Loopback
  defp private_ip?({127, _, _, _}), do: true
  # Class A private
  defp private_ip?({10, _, _, _}), do: true
  # Class B private
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  # Class C private
  defp private_ip?({192, 168, _, _}), do: true
  # Link-local / AWS metadata
  defp private_ip?({169, 254, _, _}), do: true
  # "This" network
  defp private_ip?({0, _, _, _}), do: true
  # Multicast
  defp private_ip?({224, _, _, _}), do: true
  # Reserved
  defp private_ip?({240, _, _, _}), do: true
  # Broadcast
  defp private_ip?({255, 255, 255, 255}), do: true
  defp private_ip?(_), do: false

  @doc """
  Ecto changeset validator for webhook URLs.
  Use in changesets: `|> validate_webhook_url_safe(:url)`
  """
  def validate_webhook_url_safe(changeset, field) do
    Ecto.Changeset.validate_change(changeset, field, fn _, url ->
      case validate_webhook_url(url) do
        :ok -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end
end
