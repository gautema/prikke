defmodule Prikke.Endpoints do
  @moduledoc """
  The Endpoints context for inbound webhook receivers.

  Endpoints receive webhooks from external services, store the raw payload,
  and forward it to the user's endpoint with retries and in-order delivery.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Endpoints.{Endpoint, InboundEvent}
  alias Prikke.Accounts.Organization
  alias Prikke.Tasks
  alias Prikke.Executions

  @tier_limits %{
    "free" => %{max_endpoints: 3},
    "pro" => %{max_endpoints: :unlimited}
  }

  def get_tier_limits(tier) do
    Map.get(@tier_limits, tier, @tier_limits["free"])
  end

  ## PubSub

  def subscribe_endpoints(%Organization{} = org) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "org:#{org.id}:endpoints")
  end

  defp broadcast(%Organization{} = org, message) do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "org:#{org.id}:endpoints", message)
  end

  ## CRUD

  def list_endpoints(%Organization{} = org) do
    from(e in Endpoint,
      where: e.organization_id == ^org.id,
      order_by: [desc: e.inserted_at]
    )
    |> Repo.all()
  end

  def get_endpoint!(%Organization{} = org, id) do
    Endpoint
    |> where(organization_id: ^org.id)
    |> Repo.get!(id)
  end

  def get_endpoint(%Organization{} = org, id) do
    Endpoint
    |> where(organization_id: ^org.id)
    |> Repo.get(id)
  end

  def get_endpoint_by_slug(slug) do
    Repo.one(from e in Endpoint, where: e.slug == ^slug, preload: [:organization])
  end

  def create_endpoint(%Organization{} = org, attrs, _opts \\ []) do
    changeset = Endpoint.create_changeset(%Endpoint{}, attrs, org.id)

    with :ok <- check_endpoint_limit(org),
         {:ok, endpoint} <- Repo.insert(changeset) do
      broadcast(org, {:endpoint_created, endpoint})
      {:ok, endpoint}
    else
      {:error, :endpoint_limit_reached} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(
           :base,
           "You've reached the maximum number of endpoints for your plan (#{get_tier_limits(org.tier).max_endpoints}). Upgrade to Pro for unlimited endpoints."
         )}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  def update_endpoint(%Organization{} = org, %Endpoint{} = endpoint, attrs, _opts \\ []) do
    if endpoint.organization_id != org.id do
      raise ArgumentError, "endpoint does not belong to organization"
    end

    changeset = Endpoint.changeset(endpoint, attrs)

    case Repo.update(changeset) do
      {:ok, updated} ->
        broadcast(org, {:endpoint_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_endpoint(%Organization{} = org, %Endpoint{} = endpoint, _opts \\ []) do
    if endpoint.organization_id != org.id do
      raise ArgumentError, "endpoint does not belong to organization"
    end

    case Repo.delete(endpoint) do
      {:ok, endpoint} ->
        broadcast(org, {:endpoint_deleted, endpoint})
        {:ok, endpoint}

      error ->
        error
    end
  end

  def count_endpoints(%Organization{} = org) do
    Endpoint
    |> where(organization_id: ^org.id)
    |> Repo.aggregate(:count)
  end

  def change_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
  end

  def change_new_endpoint(%Organization{} = org, attrs \\ %{}) do
    Endpoint.create_changeset(%Endpoint{}, attrs, org.id)
  end

  ## Inbound Events

  def list_inbound_events(%Endpoint{} = endpoint, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(e in InboundEvent,
      where: e.endpoint_id == ^endpoint.id,
      order_by: [desc: e.received_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:execution]
    )
    |> Repo.all()
  end

  def get_inbound_event!(%Endpoint{} = endpoint, id) do
    InboundEvent
    |> where(endpoint_id: ^endpoint.id)
    |> Repo.get!(id)
    |> Repo.preload(:execution)
  end

  def count_inbound_events(%Endpoint{} = endpoint) do
    InboundEvent
    |> where(endpoint_id: ^endpoint.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Receives an inbound webhook event.

  1. Insert inbound_event record
  2. Create a task (schedule_type: "once", url: endpoint.forward_url)
  3. Create execution for that task (scheduled_for: now)
  4. Clear next_run_at on task (so scheduler ignores it)
  5. Notify workers
  6. Update inbound_event with execution_id
  """
  def receive_event(%Endpoint{} = endpoint, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    endpoint = Repo.preload(endpoint, :organization)
    org = endpoint.organization

    # Build forwarding headers: pass through original headers but drop hop-by-hop headers
    forward_headers = filter_forward_headers(attrs.headers || %{})

    Repo.transaction(fn ->
      # 1. Create inbound event
      {:ok, event} =
        %InboundEvent{}
        |> InboundEvent.create_changeset(%{
          endpoint_id: endpoint.id,
          method: to_string(attrs.method),
          headers: attrs.headers || %{},
          body: attrs.body,
          source_ip: attrs.source_ip,
          received_at: now
        })
        |> Repo.insert()

      # 2. Create a task for forwarding
      task_attrs = %{
        "name" => "#{endpoint.name} · event #{String.slice(event.id, 0..7)}",
        "url" => endpoint.forward_url,
        "method" => to_string(attrs.method),
        "headers" => forward_headers,
        "body" => attrs.body || "",
        "schedule_type" => "once",
        "scheduled_at" => now,
        "enabled" => true,
        "timeout_ms" => 30_000,
        "retry_attempts" => 5,
        "queue" => endpoint.slug
      }

      {:ok, task} = Tasks.create_task(org, task_attrs)

      # 3. Create execution
      {:ok, execution} = Executions.create_execution_for_task(task, now)

      # 4. Clear next_run_at so scheduler ignores it
      {:ok, _task} = Tasks.clear_next_run(task)

      # 5. Notify workers
      Tasks.notify_workers()

      # 6. Update event with execution_id
      event
      |> Ecto.Changeset.change(execution_id: execution.id)
      |> Repo.update!()
    end)
  end

  @doc """
  Replays an inbound event by creating a new execution for its linked task.
  """
  def replay_event(%Endpoint{} = endpoint, %InboundEvent{} = event) do
    if event.endpoint_id != endpoint.id do
      raise ArgumentError, "event does not belong to endpoint"
    end

    execution = event.execution || Repo.preload(event, :execution).execution

    if is_nil(execution) do
      {:error, :no_execution}
    else
      task = Repo.preload(execution, :task).task
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      case Executions.create_execution_for_task(task, now) do
        {:ok, new_execution} ->
          Tasks.notify_workers()
          {:ok, new_execution}

        error ->
          error
      end
    end
  end

  ## Private

  defp check_endpoint_limit(%Organization{tier: tier} = org) do
    limits = get_tier_limits(tier)

    case limits.max_endpoints do
      :unlimited ->
        :ok

      max when is_integer(max) ->
        if count_endpoints(org) < max, do: :ok, else: {:error, :endpoint_limit_reached}
    end
  end

  @hop_by_hop_headers ~w(connection keep-alive proxy-authenticate proxy-authorization
    te trailers transfer-encoding upgrade host content-length)

  defp filter_forward_headers(headers) when is_map(headers) do
    headers
    |> Enum.reject(fn {key, _} ->
      String.downcase(to_string(key)) in @hop_by_hop_headers
    end)
    |> Map.new()
  end
end
