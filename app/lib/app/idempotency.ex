defmodule Prikke.Idempotency do
  @moduledoc """
  Handles idempotency key storage and retrieval for API requests.

  When a client sends an `Idempotency-Key` header, the response is cached
  so that retried requests with the same key return the same response
  instead of creating duplicate resources.

  Keys are scoped per organization and expire after 24 hours.
  """

  import Ecto.Query, warn: false

  alias Prikke.Repo
  alias Prikke.Idempotency.IdempotencyKey

  @default_ttl_hours 24

  @doc """
  Looks up a cached response for the given organization and idempotency key.

  Returns `{:ok, %IdempotencyKey{}}` if found, `:not_found` otherwise.
  """
  def get_cached_response(org_id, key) do
    case Repo.get_by(IdempotencyKey, organization_id: org_id, key: key) do
      nil -> :not_found
      cached -> {:ok, cached}
    end
  end

  @doc """
  Stores a response for the given organization and idempotency key.

  Uses `ON CONFLICT DO NOTHING` to handle race conditions where two
  concurrent requests with the same key both pass the initial check.
  The first one wins; the second insert is silently ignored.
  """
  def store_response(org_id, key, status_code, response_body) do
    %IdempotencyKey{}
    |> IdempotencyKey.changeset(%{
      key: key,
      status_code: status_code,
      response_body: response_body
    })
    |> Ecto.Changeset.put_change(:organization_id, org_id)
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Deletes idempotency keys older than the given TTL.

  Called periodically by the cleanup process to prevent table bloat.
  """
  def cleanup_expired_keys(ttl_hours \\ @default_ttl_hours) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_hours, :hour)

    from(k in IdempotencyKey, where: k.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end
end
