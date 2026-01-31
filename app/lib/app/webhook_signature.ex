defmodule Prikke.WebhookSignature do
  @moduledoc """
  Handles HMAC-SHA256 signature generation and verification for webhook requests.

  ## Signature Format

  The signature is computed as:
  - HMAC-SHA256(webhook_secret, request_body)
  - Encoded as lowercase hex
  - Prefixed with "sha256="

  Example: `sha256=a1b2c3d4e5f6...`

  ## Headers

  Three headers are added to every webhook request:
  - `X-Runlater-Job-Id` - The job ID
  - `X-Runlater-Execution-Id` - The execution ID (for deduplication)
  - `X-Runlater-Signature` - HMAC-SHA256 signature of the request body
  """

  @doc """
  Generates an HMAC-SHA256 signature for the given body using the secret.

  Returns the signature in the format "sha256=<hex>".

  ## Examples

      iex> Prikke.WebhookSignature.sign("request body", "whsec_abc123")
      "sha256=..."

  """
  @spec sign(binary(), binary()) :: binary()
  def sign(body, secret) when is_binary(body) and is_binary(secret) do
    signature =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    "sha256=#{signature}"
  end

  @doc """
  Verifies that a signature matches the expected signature for the given body and secret.

  Uses constant-time comparison to prevent timing attacks.

  ## Examples

      iex> signature = Prikke.WebhookSignature.sign("body", "secret")
      iex> Prikke.WebhookSignature.verify("body", "secret", signature)
      true

      iex> Prikke.WebhookSignature.verify("body", "secret", "sha256=wrong")
      false

  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(body, secret, signature) when is_binary(body) and is_binary(secret) and is_binary(signature) do
    expected = sign(body, secret)
    secure_compare(expected, signature)
  end

  @doc """
  Builds the Runlater-specific headers for a webhook request.

  Returns a list of header tuples to be added to the request.

  ## Examples

      iex> headers = Prikke.WebhookSignature.build_headers("job-123", "exec-456", "", "whsec_secret")
      iex> Enum.find(headers, fn {k, _} -> k == "x-runlater-job-id" end)
      {"x-runlater-job-id", "job-123"}

  """
  @spec build_headers(binary(), binary(), binary(), binary()) :: [{binary(), binary()}]
  def build_headers(job_id, execution_id, body, webhook_secret) do
    signature = sign(body, webhook_secret)

    [
      {"x-runlater-job-id", job_id},
      {"x-runlater-execution-id", execution_id},
      {"x-runlater-signature", signature}
    ]
  end

  # Constant-time string comparison to prevent timing attacks
  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false

  defp secure_compare(a, b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    result =
      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)

    result == 0
  end
end
