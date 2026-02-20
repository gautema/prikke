defmodule PrikkeWeb.Api.TaskController do
  @moduledoc """
  Unified task API controller.

  Handles all task types: immediate, delayed, scheduled, and cron.
  The type is inferred from the parameters provided:
  - `cron` param → recurring cron task
  - `delay` param → delayed one-time execution
  - `run_at` param → scheduled one-time execution
  - No timing param → immediate execution
  """
  use PrikkeWeb.Api.ApiController
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Tasks
  alias Prikke.Tasks.Task
  alias Prikke.Executions
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Tasks"])
  security([%{"bearerAuth" => []}])

  operation(:index,
    summary: "List all tasks",
    description:
      "Returns tasks for the authenticated organization with pagination. Optionally filter by queue name.",
    parameters: [
      queue: [
        in: :query,
        type: :string,
        description: "Filter by queue name. Use \"none\" to get tasks without a queue.",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Maximum results (1-100, default 50)",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Number of results to skip (default 0)",
        required: false
      ]
    ],
    responses: [
      ok: {"Tasks list", "application/json", Schemas.TasksResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.ErrorResponse}
    ]
  )

  def index(conn, params) do
    org = conn.assigns.current_organization
    limit = parse_limit(params["limit"], 50)
    offset = parse_offset(params["offset"])

    filter_opts = if params["queue"], do: [queue: params["queue"]], else: []
    opts = filter_opts ++ [limit: limit, offset: offset]

    # Fetch one extra to determine has_more without expensive count(*)
    tasks = Tasks.list_tasks(org, Keyword.put(opts, :limit, limit + 1))
    has_more = length(tasks) > limit
    tasks = Enum.take(tasks, limit)

    json(conn, %{
      data: Enum.map(tasks, &task_json/1),
      has_more: has_more,
      limit: limit,
      offset: offset
    })
  end

  operation(:show,
    summary: "Get a task",
    description: "Returns a single task by ID",
    parameters: [
      id: [in: :path, type: :string, description: "Task ID", required: true]
    ],
    responses: [
      ok: {"Task", "application/json", Schemas.TaskResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    org = conn.assigns.current_organization

    case Tasks.get_task(org, id) do
      nil -> {:error, :not_found}
      task -> json(conn, %{data: task_json(task)})
    end
  end

  operation(:create,
    summary: "Create a task",
    description: """
    Creates a new task. The task type is inferred from parameters:

    - Pass `cron` for a recurring task (e.g. `"cron": "*/5 * * * *"`)
    - Pass `delay` for delayed execution (e.g. `"delay": "5m"`)
    - Pass `run_at` for scheduled execution (e.g. `"run_at": "2024-01-01T00:00:00Z"`)
    - No timing parameter → immediate execution

    Supports idempotency: pass an `Idempotency-Key` header to prevent duplicate
    task creation.
    """,
    parameters: [
      "Idempotency-Key": [
        in: :header,
        type: :string,
        description: "Unique key to prevent duplicate requests (valid for 24 hours)",
        required: false
      ]
    ],
    request_body: {"Task parameters", "application/json", Schemas.TaskRequest},
    responses: [
      created: {"Task created", "application/json", Schemas.TaskResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def create(conn, params) do
    # Support both wrapped and unwrapped params
    task_params = params["task"] || params
    org = conn.assigns.current_organization
    api_key_name = conn.assigns[:api_key_name]

    cond do
      # Cron task
      task_params["cron"] ->
        create_cron_task(conn, org, task_params, api_key_name)

      # Delayed execution
      task_params["delay"] ->
        create_delayed_task(conn, org, task_params, api_key_name)

      # Scheduled execution
      task_params["run_at"] ->
        create_scheduled_task(conn, org, task_params, api_key_name)

      # Immediate execution
      true ->
        create_immediate_task(conn, org, task_params, api_key_name)
    end
  end

  operation(:update,
    summary: "Update a task",
    description: "Updates an existing task",
    parameters: [
      id: [in: :path, type: :string, description: "Task ID", required: true]
    ],
    request_body: {"Task parameters", "application/json", Schemas.TaskRequest},
    responses: [
      ok: {"Task updated", "application/json", Schemas.TaskResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    task_params = params["task"] || Map.drop(params, ["id"])
    org = conn.assigns.current_organization
    api_key_name = conn.assigns[:api_key_name]

    case Tasks.get_task(org, id) do
      nil ->
        {:error, :not_found}

      task ->
        case Tasks.update_task(org, task, task_params, api_key_name: api_key_name) do
          {:ok, task} -> json(conn, %{data: task_json(task)})
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  operation(:delete_by_queue,
    summary: "Cancel all tasks in a queue",
    description:
      "Soft-deletes all non-deleted tasks in the given queue and cancels their pending executions.",
    parameters: [
      queue: [
        in: :query,
        type: :string,
        description: "Queue name to cancel",
        required: true
      ]
    ],
    responses: [
      ok: {"Cancelled tasks", "application/json", Schemas.BulkCancelResponse},
      bad_request: {"Missing queue", "application/json", Schemas.ErrorResponse}
    ]
  )

  def delete_by_queue(conn, %{"queue" => queue}) when is_binary(queue) and queue != "" do
    org = conn.assigns.current_organization

    case Tasks.cancel_tasks_by_queue(org, queue) do
      {:ok, result} ->
        json(conn, %{
          data: %{cancelled: result.cancelled},
          message: "#{result.cancelled} tasks cancelled"
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "error", message: inspect(reason)}})
    end
  end

  def delete_by_queue(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_params", message: "queue parameter is required"}})
  end

  operation(:delete,
    summary: "Delete a task",
    description: "Deletes a task and all its execution history",
    parameters: [
      id: [in: :path, type: :string, description: "Task ID", required: true]
    ],
    responses: [
      no_content: "Task deleted",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def delete(conn, %{"id" => id}) do
    org = conn.assigns.current_organization
    api_key_name = conn.assigns[:api_key_name]

    case Tasks.get_task(org, id) do
      nil ->
        {:error, :not_found}

      task ->
        case Tasks.delete_task(org, task, api_key_name: api_key_name) do
          {:ok, _task} -> send_resp(conn, :no_content, "")
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  operation(:trigger,
    summary: "Trigger a task",
    description: "Triggers a task to run immediately, creating a pending execution",
    parameters: [
      task_id: [in: :path, type: :string, description: "Task ID", required: true]
    ],
    responses: [
      accepted: {"Task triggered", "application/json", Schemas.TriggerResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def trigger(conn, params) do
    id = params["id"] || params["task_id"]
    org = conn.assigns.current_organization

    case Tasks.get_task(org, id) do
      nil ->
        {:error, :not_found}

      task ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case Executions.create_execution_for_task(task, now) do
          {:ok, execution} ->
            Tasks.notify_workers()

            conn
            |> put_status(:accepted)
            |> json(%{
              data: %{
                execution_id: execution.id,
                status: execution.status,
                scheduled_for: execution.scheduled_for
              },
              message: "Task triggered successfully"
            })

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  operation(:executions,
    summary: "Get execution history",
    description: "Returns the execution history for a task",
    parameters: [
      task_id: [in: :path, type: :string, description: "Task ID", required: true],
      limit: [in: :query, type: :integer, description: "Maximum results (1-100, default 50)"]
    ],
    responses: [
      ok: {"Executions", "application/json", Schemas.ExecutionsResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def executions(conn, params) do
    org = conn.assigns.current_organization
    id = params["id"] || params["task_id"]
    limit = parse_limit(params["limit"], 50)

    case Tasks.get_task(org, id) do
      nil ->
        {:error, :not_found}

      task ->
        execs = Executions.list_task_executions(task, limit: limit)
        json(conn, %{data: Enum.map(execs, &execution_json/1)})
    end
  end

  # --- Private: Create helpers ---

  defp create_cron_task(conn, org, params, api_key_name) do
    task_params = %{
      "name" => params["name"] || "Cron: #{params["url"]}",
      "url" => params["url"],
      "method" => params["method"] || "GET",
      "headers" => params["headers"] || %{},
      "body" => params["body"],
      "schedule_type" => "cron",
      "cron_expression" => params["cron"],
      "enabled" => Map.get(params, "enabled", true),
      "timeout_ms" => params["timeout_ms"] || 30_000,
      "retry_attempts" => params["retry_attempts"] || 3,
      "callback_url" => params["callback_url"],
      "expected_status_codes" => params["expected_status_codes"],
      "expected_body_pattern" => params["expected_body_pattern"],
      "queue" => params["queue"],
      "notify_on_failure" => params["notify_on_failure"],
      "notify_on_recovery" => params["notify_on_recovery"]
    }

    case Tasks.create_task(org, task_params, api_key_name: api_key_name) do
      {:ok, task} ->
        conn
        |> put_status(:created)
        |> json(%{data: task_json(task), message: "Cron task created"})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp create_delayed_task(conn, org, params, api_key_name) do
    now = DateTime.utc_now()

    case parse_delay(params["delay"]) do
      {:ok, seconds} ->
        scheduled_at = DateTime.add(now, seconds, :second) |> DateTime.truncate(:second)
        do_create_once_task(conn, org, params, api_key_name, scheduled_at)

      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_delay", message: message}})
    end
  end

  defp create_scheduled_task(conn, org, params, api_key_name) do
    case DateTime.from_iso8601(params["run_at"]) do
      {:ok, scheduled_at, _offset} ->
        do_create_once_task(conn, org, params, api_key_name, scheduled_at)

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{code: "invalid_run_at", message: "run_at must be a valid ISO 8601 datetime"}
        })
    end
  end

  defp create_immediate_task(conn, org, params, api_key_name) do
    now = DateTime.utc_now()
    scheduled_at = DateTime.add(now, 1, :second) |> DateTime.truncate(:second)
    do_create_once_task(conn, org, params, api_key_name, scheduled_at)
  end

  defp do_create_once_task(conn, org, params, api_key_name, scheduled_at) do
    pretty_time = Calendar.strftime(scheduled_at, "%d %b, %H:%M")
    url = params["url"]
    default_name = "#{url} · #{pretty_time}"

    name =
      case params["name"] do
        nil -> default_name
        "" -> default_name
        n -> n
      end

    task_params = %{
      "name" => name,
      "url" => url,
      "method" => params["method"] || "POST",
      "headers" => params["headers"] || %{},
      "body" => params["body"] || "",
      "schedule_type" => "once",
      "scheduled_at" => scheduled_at,
      "enabled" => true,
      "timeout_ms" => params["timeout_ms"] || 30_000,
      "retry_attempts" => params["retry_attempts"] || 5,
      "callback_url" => params["callback_url"],
      "expected_status_codes" => params["expected_status_codes"],
      "expected_body_pattern" => params["expected_body_pattern"],
      "queue" => params["queue"],
      "notify_on_failure" => params["notify_on_failure"],
      "notify_on_recovery" => params["notify_on_recovery"]
    }

    execution_opts =
      if params["callback_url"] do
        [callback_url: params["callback_url"]]
      else
        []
      end

    # skip_next_run: task is created with next_run_at=nil, no UPDATE needed.
    # skip_ssrf: API callers authenticate with API keys and choose their own target URLs.
    result =
      Prikke.Repo.transaction(fn ->
        with {:ok, task} <-
               Tasks.create_task(org, task_params,
                 api_key_name: api_key_name,
                 skip_ssrf: true,
                 skip_next_run: true
               ),
             {:ok, execution} <-
               Executions.create_execution_for_task(task, scheduled_at, execution_opts) do
          {task, execution}
        else
          {:error, reason} -> Prikke.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {task, execution}} ->
        Tasks.notify_workers()

        conn
        |> put_status(:accepted)
        |> json(%{
          data: %{
            task_id: task.id,
            execution_id: execution.id,
            status: "pending",
            scheduled_for: execution.scheduled_for
          },
          message: "Task queued for execution"
        })

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # --- Private: JSON serialization ---

  defp task_json(%Task{} = task) do
    %{
      id: task.id,
      name: task.name,
      url: task.url,
      method: task.method,
      headers: task.headers,
      body: task.body,
      schedule_type: task.schedule_type,
      cron_expression: task.cron_expression,
      scheduled_at: task.scheduled_at,
      enabled: task.enabled,
      timeout_ms: task.timeout_ms,
      retry_attempts: task.retry_attempts,
      expected_status_codes: task.expected_status_codes,
      expected_body_pattern: task.expected_body_pattern,
      queue: task.queue,
      notify_on_failure: task.notify_on_failure,
      notify_on_recovery: task.notify_on_recovery,
      next_run_at: task.next_run_at,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp execution_json(execution) do
    %{
      id: execution.id,
      status: execution.status,
      scheduled_for: execution.scheduled_for,
      started_at: execution.started_at,
      finished_at: execution.finished_at,
      status_code: execution.status_code,
      duration_ms: execution.duration_ms,
      error_message: execution.error_message,
      attempt: execution.attempt
    }
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 100 -> 100
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_limit(_, default), do: default

  defp parse_offset(nil), do: 0

  defp parse_offset(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_offset(_), do: 0

  defp parse_delay(nil), do: {:error, "delay is required"}
  defp parse_delay(""), do: {:error, "delay is required"}

  defp parse_delay(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_delay(value) when is_integer(value), do: {:error, "delay must be a positive number"}

  defp parse_delay(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)(s|m|h|d)$/, value) do
      [_, amount, unit] ->
        seconds = String.to_integer(amount) * unit_to_seconds(unit)

        if seconds > 0,
          do: {:ok, seconds},
          else: {:error, "delay must be greater than 0"}

      nil ->
        {:error, "invalid delay format. Use a number with unit: 30s, 5m, 2h, 1d"}
    end
  end

  defp parse_delay(_),
    do: {:error, "delay must be a string (e.g. \"30s\", \"5m\") or integer (seconds)"}

  defp unit_to_seconds("s"), do: 1
  defp unit_to_seconds("m"), do: 60
  defp unit_to_seconds("h"), do: 3600
  defp unit_to_seconds("d"), do: 86400
end
