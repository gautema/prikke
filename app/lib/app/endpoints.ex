defmodule Prikke.Endpoints do
  @moduledoc """
  The Endpoints context for inbound webhook receivers.

  Endpoints receive webhooks from external services, store the raw payload,
  and forward it to the user's endpoint(s) with retries and in-order delivery.
  Fan-out: each forward URL gets its own task + execution with independent retries.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Endpoints.{Endpoint, InboundEvent}
  alias Prikke.Accounts.Organization
  alias Prikke.Audit
  alias Prikke.Tasks
  alias Prikke.Tasks.Task, as: TaskSchema
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

  def create_endpoint(%Organization{} = org, attrs, opts \\ []) do
    changeset = Endpoint.create_changeset(%Endpoint{}, attrs, org.id)

    with :ok <- check_endpoint_limit(org),
         {:ok, endpoint} <- Repo.insert(changeset) do
      broadcast(org, {:endpoint_created, endpoint})

      audit_log(opts, :created, :endpoint, endpoint.id, org.id,
        metadata: %{"endpoint_name" => endpoint.name}
      )

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

  def update_endpoint(%Organization{} = org, %Endpoint{} = endpoint, attrs, opts \\ []) do
    if endpoint.organization_id != org.id do
      raise ArgumentError, "endpoint does not belong to organization"
    end

    old_endpoint = Map.from_struct(endpoint)
    changeset = Endpoint.changeset(endpoint, attrs)

    case Repo.update(changeset) do
      {:ok, updated} ->
        broadcast(org, {:endpoint_updated, updated})

        changes =
          Audit.compute_changes(old_endpoint, Map.from_struct(updated), [
            :name,
            :forward_urls,
            :enabled,
            :retry_attempts,
            :use_queue
          ])

        audit_log(opts, :updated, :endpoint, updated.id, org.id,
          changes: changes,
          metadata: %{"endpoint_name" => updated.name}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  def delete_endpoint(%Organization{} = org, %Endpoint{} = endpoint, opts \\ []) do
    if endpoint.organization_id != org.id do
      raise ArgumentError, "endpoint does not belong to organization"
    end

    case Repo.delete(endpoint) do
      {:ok, endpoint} ->
        broadcast(org, {:endpoint_deleted, endpoint})

        audit_log(opts, :deleted, :endpoint, endpoint.id, org.id,
          metadata: %{"endpoint_name" => endpoint.name}
        )

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

  def count_all_endpoints do
    Repo.aggregate(Endpoint, :count)
  end

  def count_all_enabled_endpoints do
    from(e in Endpoint, where: e.enabled == true) |> Repo.aggregate(:count)
  end

  def count_all_inbound_events do
    Repo.aggregate(InboundEvent, :count)
  end

  def count_inbound_events_since(since) do
    from(e in InboundEvent, where: e.received_at >= ^since) |> Repo.aggregate(:count)
  end

  def list_recent_endpoints_all(opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    from(e in Endpoint,
      order_by: [desc: e.inserted_at],
      limit: ^limit,
      preload: [:organization]
    )
    |> Repo.all()
  end

  def change_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
  end

  def change_new_endpoint(%Organization{} = org, attrs \\ %{}) do
    Endpoint.create_changeset(%Endpoint{}, attrs, org.id)
  end

  def get_last_event_status(%Endpoint{} = endpoint) do
    event =
      from(e in InboundEvent,
        where: e.endpoint_id == ^endpoint.id,
        order_by: [desc: e.received_at],
        limit: 1
      )
      |> Repo.one()

    case event do
      nil ->
        nil

      %{task_ids: []} ->
        "pending"

      %{task_ids: task_ids} ->
        tasks = load_tasks_with_latest_execution(task_ids)
        aggregate_task_statuses(tasks)
    end
  end

  ## Inbound Events

  def list_inbound_events(%Endpoint{} = endpoint, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    events =
      from(e in InboundEvent,
        where: e.endpoint_id == ^endpoint.id,
        order_by: [desc: e.received_at],
        limit: ^limit,
        offset: ^offset
      )
      |> Repo.all()

    # Batch-load tasks for all events to compute aggregated status
    all_task_ids =
      events
      |> Enum.flat_map(& &1.task_ids)
      |> Enum.uniq()

    tasks_by_id =
      if all_task_ids == [] do
        %{}
      else
        load_tasks_with_latest_execution(all_task_ids)
        |> Map.new(&{&1.id, &1})
      end

    Enum.map(events, fn event ->
      tasks = Enum.map(event.task_ids, &Map.get(tasks_by_id, &1)) |> Enum.reject(&is_nil/1)
      Map.put(event, :tasks, tasks)
    end)
  end

  def get_inbound_event!(%Endpoint{} = endpoint, id) do
    event =
      InboundEvent
      |> where(endpoint_id: ^endpoint.id)
      |> Repo.get!(id)

    tasks = load_tasks_with_latest_execution(event.task_ids)
    Map.put(event, :tasks, tasks)
  end

  def count_inbound_events(%Endpoint{} = endpoint) do
    InboundEvent
    |> where(endpoint_id: ^endpoint.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Receives an inbound webhook event with fan-out.

  1. Insert inbound_event record
  2. For each forward URL: create a task + execution
  3. Update event with task_ids
  4. Notify workers once
  """
  def receive_event(%Endpoint{} = endpoint, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    endpoint = Repo.preload(endpoint, :organization)
    org = endpoint.organization

    # Build forwarding headers: pass through original headers but drop hop-by-hop headers
    forward_headers = filter_forward_headers(attrs.headers || %{})

    result =
      Repo.transaction(fn ->
        # 1. Create inbound event (task_ids populated after)
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

        url_count = length(endpoint.forward_urls)
        event_short_id = String.slice(event.id, 0..7)

        # 2. For each forward URL, create task + execution
        task_ids =
          endpoint.forward_urls
          |> Enum.with_index(1)
          |> Enum.map(fn {url, idx} ->
            task_name =
              if url_count == 1 do
                "#{endpoint.name} \u00b7 event #{event_short_id}"
              else
                "#{endpoint.name} \u00b7 event #{event_short_id} \u2192 #{idx}/#{url_count}"
              end

            task_attrs = %{
              "name" => task_name,
              "url" => url,
              "method" => to_string(attrs.method),
              "headers" => forward_headers,
              "body" => attrs.body || "",
              "schedule_type" => "once",
              "scheduled_at" => now,
              "enabled" => true,
              "timeout_ms" => 30_000,
              "retry_attempts" => endpoint.retry_attempts,
              "queue" => if(endpoint.use_queue, do: slugify_name(endpoint.name), else: nil),
              "notify_on_failure" => endpoint.notify_on_failure,
              "notify_on_recovery" => endpoint.notify_on_recovery
            }

            # skip_next_run: task is created with next_run_at=nil, no UPDATE needed
            {:ok, task} = Tasks.create_task(org, task_attrs, skip_next_run: true)

            # 3. Create execution
            {:ok, _execution} = Executions.create_execution_for_task(task, now)

            task.id
          end)

        # 4. Update event with task_ids
        event
        |> Ecto.Changeset.change(task_ids: task_ids)
        |> Repo.update!()
      end)

    # Notify workers after transaction commits
    Tasks.notify_workers()

    result
  end

  @doc """
  Replays an inbound event by creating new executions for all linked tasks.
  """
  def replay_event(%Endpoint{} = endpoint, %InboundEvent{} = event) do
    if event.endpoint_id != endpoint.id do
      raise ArgumentError, "event does not belong to endpoint"
    end

    task_ids = event.task_ids

    if task_ids == [] do
      {:error, :no_tasks}
    else
      tasks = load_tasks_by_ids(task_ids)

      if Enum.empty?(tasks) do
        {:error, :task_deleted}
      else
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        executions =
          Enum.map(tasks, fn task ->
            {:ok, exec} = Executions.create_execution_for_task(task, now)
            exec
          end)

        Tasks.notify_workers()
        {:ok, executions}
      end
    end
  end

  ## Private: Task loading helpers

  defp load_tasks_by_ids([]), do: []

  defp load_tasks_by_ids(task_ids) do
    from(t in TaskSchema, where: t.id in ^task_ids)
    |> Repo.all()
  end

  defp load_tasks_with_latest_execution([]), do: []

  defp load_tasks_with_latest_execution(task_ids) do
    tasks = load_tasks_by_ids(task_ids)

    # Get latest execution for each task
    latest_executions =
      from(e in Prikke.Executions.Execution,
        where: e.task_id in ^task_ids,
        distinct: e.task_id,
        order_by: [e.task_id, desc: e.inserted_at]
      )
      |> Repo.all()
      |> Map.new(&{&1.task_id, &1})

    Enum.map(tasks, fn task ->
      Map.put(task, :latest_execution, Map.get(latest_executions, task.id))
    end)
  end

  @doc """
  Computes an aggregated status from a list of tasks with latest_execution.
  """
  def aggregate_task_statuses([]), do: nil

  def aggregate_task_statuses(tasks) do
    statuses =
      Enum.map(tasks, fn task ->
        case Map.get(task, :latest_execution) do
          nil -> "pending"
          exec -> exec.status
        end
      end)

    cond do
      Enum.any?(statuses, &(&1 in ["failed", "timeout"])) -> "failed"
      Enum.any?(statuses, &(&1 in ["pending", "running"])) -> "pending"
      Enum.all?(statuses, &(&1 == "success")) -> "success"
      true -> "pending"
    end
  end

  ## Private

  defp slugify_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end

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

  ## Private: Audit Logging

  defp audit_log(opts, action, resource_type, resource_id, org_id, extra_opts) do
    scope = Keyword.get(opts, :scope)
    api_key_name = Keyword.get(opts, :api_key_name)
    changes = Keyword.get(extra_opts, :changes, %{})
    metadata = Keyword.get(extra_opts, :metadata, %{})

    cond do
      scope != nil ->
        Audit.log(scope, action, resource_type, resource_id,
          organization_id: org_id,
          changes: changes,
          metadata: metadata
        )

      api_key_name != nil ->
        Audit.log_api(api_key_name, action, resource_type, resource_id,
          organization_id: org_id,
          changes: changes,
          metadata: metadata
        )

      true ->
        :ok
    end
  end
end
