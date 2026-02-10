defmodule Prikke.Tasks do
  @moduledoc """
  The Tasks context.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Tasks.Task
  alias Prikke.Accounts.Organization
  alias Prikke.Audit

  # Tier limits
  @tier_limits %{
    "free" => %{
      max_tasks: :unlimited,
      min_interval_minutes: 60,
      max_monthly_executions: 5_000,
      retention_days: 7
    },
    "pro" => %{
      max_tasks: :unlimited,
      min_interval_minutes: 1,
      max_monthly_executions: 1_000_000,
      retention_days: 30
    }
  }

  def tier_limits, do: @tier_limits

  def get_tier_limits(tier) do
    Map.get(@tier_limits, tier, @tier_limits["free"])
  end

  @doc """
  Subscribes to notifications about task changes for an organization.

  The broadcasted messages match the pattern:

    * {:created, %Task{}}
    * {:updated, %Task{}}
    * {:deleted, %Task{}}

  """
  def subscribe_tasks(%Organization{} = org) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "org:#{org.id}:tasks")
  end

  defp broadcast(%Organization{} = org, message) do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "org:#{org.id}:tasks", message)
  end

  @doc """
  Notifies the scheduler to wake up and check for due tasks.
  Called when a task is created or enabled.
  """
  def notify_scheduler do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "scheduler", :wake)
  end

  @doc """
  Notifies workers to wake up and check for pending executions.
  Called when new executions are created.
  """
  def notify_workers do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "workers", :wake)
  end

  @doc """
  Returns the list of tasks for an organization.

  ## Options

    * `:queue` - filter by queue name. Use `"none"` to match tasks with no queue.
    * `:type` - filter by schedule type. `"cron"` for recurring, `"once"` for one-time.
    * `:limit` - maximum number of tasks to return (default 50, max 100).
    * `:offset` - number of tasks to skip (default 0).
  """
  def list_tasks(%Organization{} = org, opts \\ []) do
    queue = Keyword.get(opts, :queue)
    type = Keyword.get(opts, :type)
    limit = opts |> Keyword.get(:limit, 50) |> min(100) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    # LATERAL join: one index lookup per task instead of scanning all executions.
    # For each task, Postgres does a backward index scan on (task_id, scheduled_for)
    # and returns just the top row. With 1000 tasks this is ~1000 index probes
    # vs scanning 60k+ execution rows with the old GROUP BY subquery.
    query =
      from(t in Task,
        where: t.organization_id == ^org.id,
        left_lateral_join:
          le in fragment(
            "(SELECT e.scheduled_for AS last_exec FROM executions e WHERE e.task_id = ? ORDER BY e.scheduled_for DESC LIMIT 1)",
            t.id
          ),
        on: true,
        order_by: [desc_nulls_last: le.last_exec, desc: t.inserted_at],
        select: t
      )

    query =
      case queue do
        nil -> query
        "none" -> from(t in query, where: is_nil(t.queue))
        name -> from(t in query, where: t.queue == ^name)
      end

    query =
      case type do
        nil -> query
        schedule_type -> from(t in query, where: t.schedule_type == ^schedule_type)
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Counts tasks for an organization with optional filters.

  ## Options

    * `:queue` - filter by queue name. Use `"none"` to match tasks with no queue.
    * `:type` - filter by schedule type. `"cron"` for recurring, `"once"` for one-time.
  """
  def count_tasks(%Organization{} = org, opts) when is_list(opts) do
    queue = Keyword.get(opts, :queue)
    type = Keyword.get(opts, :type)

    query = from(t in Task, where: t.organization_id == ^org.id)

    query =
      case queue do
        nil -> query
        "none" -> from(t in query, where: is_nil(t.queue))
        name -> from(t in query, where: t.queue == ^name)
      end

    query =
      case type do
        nil -> query
        schedule_type -> from(t in query, where: t.schedule_type == ^schedule_type)
      end

    Repo.aggregate(query, :count)
  end

  @doc """
  Returns distinct non-nil queue names for an organization.
  """
  def list_queues(%Organization{} = org) do
    from(t in Task,
      where: t.organization_id == ^org.id,
      where: not is_nil(t.queue),
      distinct: true,
      select: t.queue,
      order_by: t.queue
    )
    |> Repo.all()
  end

  @doc """
  Returns cron tasks for an organization.
  """
  def list_cron_tasks(%Organization{} = org) do
    Task
    |> where(organization_id: ^org.id)
    |> where([t], t.schedule_type == "cron")
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns one-time tasks for an organization, with optional queue filter.
  """
  def list_once_tasks(%Organization{} = org, opts \\ []) do
    queue = Keyword.get(opts, :queue)

    query =
      Task
      |> where(organization_id: ^org.id)
      |> where([t], t.schedule_type == "once")
      |> order_by([t], desc: t.inserted_at)

    query =
      if queue do
        from(t in query, where: t.queue == ^queue)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns enabled tasks for an organization.
  """
  def list_enabled_tasks(%Organization{} = org) do
    Task
    |> where(organization_id: ^org.id)
    |> where(enabled: true)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single task. Raises if not found.
  """
  def get_task!(%Organization{} = org, id) do
    Task
    |> where(organization_id: ^org.id)
    |> Repo.get!(id)
  end

  @doc """
  Gets a single task, returns nil if not found.
  """
  def get_task(%Organization{} = org, id) do
    Task
    |> where(organization_id: ^org.id)
    |> Repo.get(id)
  end

  @doc """
  Creates a task for an organization.

  Enforces tier limits on cron intervals.
  """
  def create_task(%Organization{} = org, attrs, opts \\ []) do
    changeset_opts = Keyword.take(opts, [:skip_ssrf, :skip_next_run])
    changeset = Task.create_changeset(%Task{}, attrs, org.id, changeset_opts)

    with :ok <- check_interval_limit(org, changeset),
         {:ok, task} <- Repo.insert(changeset) do
      broadcast(org, {:created, task})

      if task.schedule_type == "cron" do
        audit_log(opts, :created, :task, task.id, org.id, metadata: %{"task_name" => task.name})
      end

      {:ok, task}
    else
      {:error, :interval_too_frequent} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(
           :cron_expression,
           "Free plan only allows hourly or less frequent schedules. Upgrade to Pro for per-minute scheduling."
         )}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  defp check_interval_limit(%Organization{tier: tier}, changeset) do
    limits = get_tier_limits(tier)
    schedule_type = Ecto.Changeset.get_field(changeset, :schedule_type)
    interval = Ecto.Changeset.get_field(changeset, :interval_minutes)

    cond do
      # One-time tasks are always allowed
      schedule_type == "once" -> :ok
      # No interval computed yet (validation will fail elsewhere)
      is_nil(interval) -> :ok
      # Check minimum interval
      interval >= limits.min_interval_minutes -> :ok
      true -> {:error, :interval_too_frequent}
    end
  end

  @doc """
  Updates a task.

  Enforces tier limits on interval changes.
  """
  def update_task(%Organization{} = org, %Task{} = task, attrs, opts \\ []) do
    if task.organization_id != org.id do
      raise ArgumentError, "task does not belong to organization"
    end

    changeset = Task.changeset(task, attrs)

    was_enabled = task.enabled
    old_task = Map.from_struct(task)

    with :ok <- check_interval_limit(org, changeset),
         {:ok, updated_task} <- Repo.update(changeset) do
      broadcast(org, {:updated, updated_task})
      # Notify scheduler if task was just enabled, or if schedule changed to be due soon
      if updated_task.enabled && updated_task.next_run_at do
        just_enabled = !was_enabled && updated_task.enabled
        due_soon = DateTime.diff(updated_task.next_run_at, DateTime.utc_now()) <= 60
        if just_enabled || due_soon, do: notify_scheduler()
      end

      # Audit log with changes
      changes =
        Audit.compute_changes(old_task, Map.from_struct(updated_task), [
          :name,
          :url,
          :method,
          :headers,
          :body,
          :schedule_type,
          :cron_expression,
          :scheduled_at,
          :enabled,
          :timeout_ms,
          :retry_attempts
        ])

      if updated_task.schedule_type == "cron" do
        audit_log(opts, :updated, :task, updated_task.id, org.id,
          changes: changes,
          metadata: %{"task_name" => updated_task.name}
        )
      end

      {:ok, updated_task}
    else
      {:error, :interval_too_frequent} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(
           :cron_expression,
           "Free plan only allows hourly or less frequent schedules. Upgrade to Pro for per-minute scheduling."
         )}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  @doc """
  Clears the next_run_at field for a task.

  This is used when an execution has been manually created (e.g., via API)
  to prevent the scheduler from also creating an execution for the same task.
  """
  def clear_next_run(%Task{} = task) do
    task
    |> Ecto.Changeset.change(next_run_at: nil)
    |> Repo.update()
  end

  @doc """
  Deletes a task.
  """
  def delete_task(%Organization{} = org, %Task{} = task, opts \\ []) do
    if task.organization_id != org.id do
      raise ArgumentError, "task does not belong to organization"
    end

    with {:ok, task} <- Repo.delete(task) do
      broadcast(org, {:deleted, task})

      if task.schedule_type == "cron" do
        audit_log(opts, :deleted, :task, task.id, org.id, metadata: %{"task_name" => task.name})
      end

      {:ok, task}
    end
  end

  @doc """
  Toggles a task's enabled status.
  When enabling, resets next_run_at to avoid creating missed executions.
  """
  def toggle_task(%Organization{} = org, %Task{} = task, opts \\ []) do
    if task.organization_id != org.id do
      raise ArgumentError, "task does not belong to organization"
    end

    action = if task.enabled, do: :disabled, else: :enabled

    changeset =
      if task.enabled do
        Ecto.Changeset.change(task, enabled: false, next_run_at: nil)
      else
        Ecto.Changeset.change(task,
          enabled: true,
          next_run_at: compute_next_run_for_enable(task)
        )
      end

    case Repo.update(changeset) do
      {:ok, updated_task} ->
        broadcast(org, {:updated, updated_task})

        if updated_task.enabled && updated_task.next_run_at do
          notify_scheduler()
        end

        if updated_task.schedule_type == "cron" do
          audit_log(opts, action, :task, updated_task.id, org.id,
            metadata: %{"task_name" => updated_task.name}
          )
        end

        {:ok, updated_task}

      error ->
        error
    end
  end

  defp compute_next_run_for_enable(%Task{schedule_type: "cron"} = task) do
    case Crontab.CronExpression.Parser.parse(task.cron_expression) do
      {:ok, cron} ->
        now = DateTime.utc_now()

        case Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(now)) do
          {:ok, naive_next} -> DateTime.from_naive!(naive_next, "Etc/UTC")
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp compute_next_run_for_enable(%Task{schedule_type: "once"} = task) do
    if task.scheduled_at && DateTime.compare(task.scheduled_at, DateTime.utc_now()) == :gt do
      task.scheduled_at
    else
      nil
    end
  end

  defp compute_next_run_for_enable(_task), do: nil

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking task changes.
  """
  def change_task(%Task{} = task, attrs \\ %{}) do
    Task.changeset(task, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for creating a new task.
  """
  def change_new_task(%Organization{} = org, attrs \\ %{}) do
    Task.create_changeset(%Task{}, attrs, org.id)
  end

  @doc """
  Counts tasks for an organization.
  """
  def count_tasks(%Organization{} = org) do
    Task
    |> where(organization_id: ^org.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts enabled tasks for an organization.
  """
  def count_enabled_tasks(%Organization{} = org) do
    Task
    |> where(organization_id: ^org.id)
    |> where(enabled: true)
    |> Repo.aggregate(:count)
  end

  @doc """
  Deletes completed one-time tasks older than retention_days.

  A one-time task is "completed" when next_run_at is nil (already executed).
  """
  def cleanup_completed_once_tasks(%Organization{} = org, retention_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days, :day)

    from(t in Task,
      where: t.organization_id == ^org.id,
      where: t.schedule_type == "once",
      where: is_nil(t.next_run_at),
      where: t.updated_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  @doc """
  Clones a task, creating a copy with "(copy)" suffix.

  For one-time tasks with a past `scheduled_at`, adjusts to 1 hour from now.
  Reuses `create_task/3` so all validation and tier limits apply.
  """
  def clone_task(%Organization{} = org, %Task{} = task, opts \\ []) do
    scheduled_at =
      if task.schedule_type == "once" do
        if task.scheduled_at && DateTime.compare(task.scheduled_at, DateTime.utc_now()) == :gt do
          task.scheduled_at
        else
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
        end
      else
        task.scheduled_at
      end

    attrs = %{
      name: "#{task.name} (copy)",
      url: task.url,
      method: task.method,
      headers: task.headers,
      body: task.body,
      schedule_type: task.schedule_type,
      cron_expression: task.cron_expression,
      scheduled_at: scheduled_at,
      timeout_ms: task.timeout_ms,
      retry_attempts: task.retry_attempts,
      callback_url: task.callback_url,
      expected_status_codes: task.expected_status_codes,
      expected_body_pattern: task.expected_body_pattern,
      queue: task.queue,
      enabled: true
    }

    create_task(org, attrs, opts)
  end

  @doc """
  Tests a webhook URL by making a real HTTP request without creating any execution records.
  """
  def test_webhook(params) do
    url = Map.get(params, :url) || Map.get(params, "url", "")
    method = Map.get(params, :method) || Map.get(params, "method", "GET")
    headers_raw = Map.get(params, :headers) || Map.get(params, "headers", %{})
    body = Map.get(params, :body) || Map.get(params, "body")
    timeout_ms = Map.get(params, :timeout_ms) || Map.get(params, "timeout_ms", 10_000)

    # Cap timeout at 10 seconds for test requests
    timeout_ms = min(timeout_ms, 10_000)

    headers =
      case headers_raw do
        h when is_map(h) -> Enum.map(h, fn {k, v} -> {to_string(k), to_string(v)} end)
        h when is_list(h) -> h
        _ -> []
      end

    method_atom =
      method
      |> to_string()
      |> String.downcase()
      |> String.to_existing_atom()

    opts = [
      method: method_atom,
      url: url,
      headers: headers,
      receive_timeout: timeout_ms,
      connect_options: [timeout: 5_000],
      retry: false
    ]

    opts =
      if method in ["POST", "PUT", "PATCH", "post", "put", "patch"] and body do
        Keyword.put(opts, :body, body)
      else
        opts
      end

    start_time = System.monotonic_time(:millisecond)

    case Req.request(opts) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        response_body = truncate_test_body(response.body)

        {:ok,
         %{
           status: response.status,
           duration_ms: duration_ms,
           body: response_body
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        {:error, "Request timed out after #{duration_ms}ms"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Connection error: #{inspect(reason)}"}

      {:error, error} ->
        {:error, "Request failed: #{inspect(error)}"}
    end
  end

  @max_test_body_size 4 * 1024

  defp truncate_test_body(nil), do: nil

  defp truncate_test_body(body) when is_binary(body) do
    if byte_size(body) > @max_test_body_size do
      String.slice(body, 0, @max_test_body_size) <> "... [truncated]"
    else
      body
    end
  end

  defp truncate_test_body(body), do: inspect(body)

  @doc """
  Parses a comma-separated string of status codes into a list of integers.
  Returns an empty list for nil or empty string.
  """
  def parse_status_codes(nil), do: []
  def parse_status_codes(""), do: []

  def parse_status_codes(codes) when is_binary(codes) do
    codes
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
  end

  ## Platform-wide Stats (for superadmin)

  @doc """
  Counts total tasks across all organizations.
  """
  def count_all_tasks do
    Repo.aggregate(Task, :count)
  end

  @doc """
  Counts enabled tasks across all organizations.
  """
  def count_all_enabled_tasks do
    from(t in Task, where: t.enabled == true)
    |> Repo.aggregate(:count)
  end

  @doc """
  Lists recently created tasks across all organizations.
  """
  def list_recent_tasks_all(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(t in Task,
      order_by: [desc: t.inserted_at],
      limit: ^limit,
      preload: [:organization]
    )
    |> Repo.all()
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
