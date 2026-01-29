defmodule PrikkeWeb.Api.JobController do
  use PrikkeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Jobs
  alias Prikke.Jobs.Job
  alias Prikke.Executions
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags ["Jobs"]
  security [%{"bearerAuth" => []}]

  operation :index,
    summary: "List all jobs",
    description: "Returns all jobs for the authenticated organization",
    responses: [
      ok: {"Jobs list", "application/json", Schemas.JobsResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, _params) do
    org = conn.assigns.current_organization
    jobs = Jobs.list_jobs(org)
    json(conn, %{data: Enum.map(jobs, &job_json/1)})
  end

  operation :show,
    summary: "Get a job",
    description: "Returns a single job by ID",
    parameters: [
      id: [in: :path, type: :string, description: "Job ID", required: true]
    ],
    responses: [
      ok: {"Job", "application/json", Schemas.JobResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def show(conn, %{"id" => id}) do
    org = conn.assigns.current_organization

    case Jobs.get_job(org, id) do
      nil -> {:error, :not_found}
      job -> json(conn, %{data: job_json(job)})
    end
  end

  operation :create,
    summary: "Create a job",
    description: "Creates a new scheduled job",
    request_body: {"Job parameters", "application/json", Schemas.JobRequest},
    responses: [
      created: {"Job created", "application/json", Schemas.JobResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, %{"job" => job_params}) do
    org = conn.assigns.current_organization

    case Jobs.create_job(org, job_params) do
      {:ok, job} ->
        conn
        |> put_status(:created)
        |> json(%{data: job_json(job)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def create(conn, params) do
    # Allow params without "job" wrapper
    create(conn, %{"job" => params})
  end

  operation :update,
    summary: "Update a job",
    description: "Updates an existing job",
    parameters: [
      id: [in: :path, type: :string,  description: "Job ID", required: true]
    ],
    request_body: {"Job parameters", "application/json", Schemas.JobRequest},
    responses: [
      ok: {"Job updated", "application/json", Schemas.JobResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]

  def update(conn, %{"id" => id, "job" => job_params}) do
    org = conn.assigns.current_organization

    case Jobs.get_job(org, id) do
      nil ->
        {:error, :not_found}

      job ->
        case Jobs.update_job(org, job, job_params) do
          {:ok, job} -> json(conn, %{data: job_json(job)})
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  def update(conn, %{"id" => id} = params) do
    # Allow params without "job" wrapper
    job_params = Map.drop(params, ["id"])
    update(conn, %{"id" => id, "job" => job_params})
  end

  operation :delete,
    summary: "Delete a job",
    description: "Deletes a job and all its execution history",
    parameters: [
      id: [in: :path, type: :string,  description: "Job ID", required: true]
    ],
    responses: [
      no_content: "Job deleted",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def delete(conn, %{"id" => id}) do
    org = conn.assigns.current_organization

    case Jobs.get_job(org, id) do
      nil ->
        {:error, :not_found}

      job ->
        case Jobs.delete_job(org, job) do
          {:ok, _job} -> send_resp(conn, :no_content, "")
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  operation :trigger,
    summary: "Trigger a job",
    description: "Triggers a job to run immediately, creating a pending execution",
    parameters: [
      job_id: [in: :path, type: :string,  description: "Job ID", required: true]
    ],
    responses: [
      accepted: {"Job triggered", "application/json", Schemas.TriggerResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def trigger(conn, params) do
    id = params["id"] || params["job_id"]
    org = conn.assigns.current_organization

    case Jobs.get_job(org, id) do
      nil ->
        {:error, :not_found}

      job ->
        # Create an execution scheduled for now
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case Executions.create_execution_for_job(job, now) do
          {:ok, execution} ->
            # Wake the workers to pick it up
            Jobs.notify_scheduler()

            conn
            |> put_status(:accepted)
            |> json(%{
              data: %{
                execution_id: execution.id,
                status: execution.status,
                scheduled_for: execution.scheduled_for
              },
              message: "Job triggered successfully"
            })

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  operation :executions,
    summary: "Get execution history",
    description: "Returns the execution history for a job",
    parameters: [
      job_id: [in: :path, type: :string,  description: "Job ID", required: true],
      limit: [in: :query, type: :integer, description: "Maximum results (1-100, default 50)"]
    ],
    responses: [
      ok: {"Executions", "application/json", Schemas.ExecutionsResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]

  def executions(conn, params) do
    org = conn.assigns.current_organization
    id = params["id"] || params["job_id"]
    limit = parse_limit(params["limit"], 50)

    case Jobs.get_job(org, id) do
      nil ->
        {:error, :not_found}

      job ->
        execs = Executions.list_job_executions(job, limit: limit)
        json(conn, %{data: Enum.map(execs, &execution_json/1)})
    end
  end

  # JSON serialization helpers

  defp job_json(%Job{} = job) do
    %{
      id: job.id,
      name: job.name,
      url: job.url,
      method: job.method,
      headers: job.headers,
      body: job.body,
      schedule_type: job.schedule_type,
      cron_expression: job.cron_expression,
      scheduled_at: job.scheduled_at,
      timezone: job.timezone,
      enabled: job.enabled,
      timeout_ms: job.timeout_ms,
      retry_attempts: job.retry_attempts,
      next_run_at: job.next_run_at,
      inserted_at: job.inserted_at,
      updated_at: job.updated_at
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
      {n, _} when n > 0 and n <= 100 -> n
      _ -> default
    end
  end
  defp parse_limit(_, default), do: default
end
