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
    summary: "Queue a request for immediate or delayed execution",
    description: """
    Queues an HTTP request for execution. By default runs immediately, or pass a
    `delay` parameter to defer execution (e.g. "30s", "5m", "2h", "1d").

    The request is queued and executed by the worker pool.

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

    now = DateTime.utc_now()

    scheduled_at =
      case parse_delay(params["delay"]) do
        {:ok, seconds} ->
          DateTime.add(now, seconds, :second) |> DateTime.truncate(:second)

        {:error, message} ->
          {:error, message}

        nil ->
          # No delay — schedule 1 second in the future to pass validation
          DateTime.add(now, 1, :second) |> DateTime.truncate(:second)
      end

    case scheduled_at do
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_delay", message: message}})

      scheduled_at ->
        do_push(conn, params, org, api_key_name, scheduled_at)
    end
  end

  defp do_push(conn, params, org, api_key_name, scheduled_at) do

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
      "callback_url" => params["callback_url"],
      "expected_status_codes" => params["expected_status_codes"],
      "expected_body_pattern" => params["expected_body_pattern"]
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
        message: "Request queued for execution"
      })
    end
  end

  @doc false
  defp parse_delay(nil), do: nil
  defp parse_delay(""), do: nil

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

  defp parse_delay(_), do: {:error, "delay must be a string (e.g. \"30s\", \"5m\") or integer (seconds)"}

  defp unit_to_seconds("s"), do: 1
  defp unit_to_seconds("m"), do: 60
  defp unit_to_seconds("h"), do: 3600
  defp unit_to_seconds("d"), do: 86400
end
