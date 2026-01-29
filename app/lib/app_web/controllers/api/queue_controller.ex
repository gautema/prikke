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

  tags ["Queue"]
  security [%{"bearerAuth" => []}]

  operation :push,
    summary: "Queue a request for immediate execution",
    description: """
    Queues an HTTP request for immediate execution. This is the simplest way to
    execute a webhook - just provide the URL and optional settings.

    The request is queued and executed by the worker pool, typically within seconds.
    """,
    request_body: {"Queue request", "application/json", Schemas.QueueRequest, required: true},
    responses: [
      accepted: {"Request queued", "application/json", Schemas.QueueResponse},
      bad_request: {"Invalid request", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]

  def push(conn, params) do
    org = conn.assigns.current_organization
    # Schedule 1 second in the future to pass validation, will execute immediately
    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(1, :second)
      |> DateTime.truncate(:second)

    # Generate a name if not provided
    name = params["name"] || "Queue #{DateTime.to_iso8601(scheduled_at)}"

    job_params = %{
      "name" => name,
      "url" => params["url"],
      "method" => params["method"] || "POST",
      "headers" => params["headers"] || %{},
      "body" => params["body"] || "",
      "schedule_type" => "once",
      "scheduled_at" => scheduled_at,
      "enabled" => true,
      "timeout_ms" => params["timeout_ms"] || 30_000
    }

    with {:ok, job} <- Jobs.create_job(org, job_params),
         {:ok, execution} <- Executions.create_execution_for_job(job, scheduled_at) do
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
