defmodule PrikkeWeb.Api.QueueController do
  @moduledoc """
  On-demand queue API for immediate job execution.

  This provides a simpler API than creating a job + triggering it.
  Just POST the webhook details and it executes immediately.
  """
  use PrikkeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Jobs
  alias Prikke.Executions
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Queue"])
  security([%{"bearerAuth" => []}])

  operation(:push,
    summary: "Queue a request for immediate execution",
    description: """
    Queues an HTTP request for immediate execution. This is the simplest way to
    execute a webhook - just provide the URL and optional settings.

    The request is queued and executed by the worker pool, typically within seconds.

    Supports idempotency: pass an `Idempotency-Key` header to prevent duplicate
    requests. If the same key is sent again within 24 hours, the original response
    is returned without creating a new job.
    """,
    parameters: [
      "Idempotency-Key": [
        in: :header,
        type: :string,
        description: "Unique key to prevent duplicate requests (valid for 24 hours)",
        required: false
      ]
    ],
    request_body: {"Queue request", "application/json", Schemas.QueueRequest, required: true},
    responses: [
      accepted: {"Request queued", "application/json", Schemas.QueueResponse},
      bad_request: {"Invalid request", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def push(conn, params) do
    org = conn.assigns.current_organization
    api_key_name = conn.assigns[:api_key_name]
    # Schedule 1 second in the future to pass validation, will execute immediately
    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(1, :second)
      |> DateTime.truncate(:second)

    # Generate a name if not provided or empty
    url = params["url"]
    pretty_time = Calendar.strftime(scheduled_at, "%d %b, %H:%M")
    default_name = "#{url} · #{pretty_time}"

    name =
      case params["name"] do
        nil -> default_name
        "" -> default_name
        n -> n
      end

    job_params = %{
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
      "callback_url" => params["callback_url"]
    }

    # Per-push callback_url override: pass to execution if provided
    execution_opts =
      if params["callback_url"] do
        [callback_url: params["callback_url"]]
      else
        []
      end

    with {:ok, job} <- Jobs.create_job(org, job_params, api_key_name: api_key_name),
         {:ok, execution} <- Executions.create_execution_for_job(job, scheduled_at, execution_opts),
         # Clear next_run_at so scheduler doesn't also create an execution
         {:ok, _job} <- Jobs.clear_next_run(job) do
      # Wake workers to process immediately
      Jobs.notify_workers()

      conn
      |> put_status(:accepted)
      |> json(%{
        data: %{
          job_id: job.id,
          execution_id: execution.id,
          status: "pending",
          scheduled_for: execution.scheduled_for
        },
        message: "Request queued for immediate execution"
      })
    end
  end
end
