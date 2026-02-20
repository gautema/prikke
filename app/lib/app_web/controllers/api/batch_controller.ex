defmodule PrikkeWeb.Api.BatchController do
  @moduledoc """
  API controller for batch task operations.

  Allows creating many tasks at once with shared configuration
  and individual request bodies.
  """
  use PrikkeWeb.Api.ApiController
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Tasks
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Tasks"])
  security([%{"bearerAuth" => []}])

  operation(:create,
    summary: "Create tasks in batch",
    description: """
    Creates multiple tasks at once with shared configuration. Each item in the `items`
    array becomes the request body for an individual task. All tasks share the same URL,
    method, headers, timing, queue, and other settings.

    - Max 1000 items per request
    - `url` and `queue` are required
    - Pass `run_at` for scheduled, `delay` for delayed, omit both for immediate
    """,
    request_body: {"Batch parameters", "application/json", Schemas.BatchRequest},
    responses: [
      created: {"Batch created", "application/json", Schemas.BatchResponse},
      bad_request: {"Validation error", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def create(conn, params) do
    org = conn.assigns.current_organization
    items = params["items"]

    cond do
      !is_list(items) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_params", message: "items must be a list"}})

      true ->
        shared_attrs = Map.drop(params, ["items"])

        case Tasks.create_batch(org, shared_attrs, items) do
          {:ok, result} ->
            conn
            |> put_status(:created)
            |> json(%{
              data: %{
                queue: result.queue,
                created: result.created,
                scheduled_for: result.scheduled_for
              },
              message: "#{result.created} tasks created"
            })

          {:error, :empty_items} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "invalid_params", message: "items must not be empty"}})

          {:error, :too_many_items} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: %{code: "invalid_params", message: "items must not exceed 1000 elements"}
            })

          {:error, :monthly_limit_exceeded} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: "limit_exceeded",
                message: "Monthly execution limit would be exceeded"
              }
            })

          {:error, :url_required} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "invalid_params", message: "url is required"}})

          {:error, :queue_required} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "invalid_params", message: "queue is required"}})

          {:error, :invalid_url} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: %{code: "invalid_params", message: "url must be a valid HTTP or HTTPS URL"}
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "error", message: inspect(reason)}})
        end
    end
  end
end
