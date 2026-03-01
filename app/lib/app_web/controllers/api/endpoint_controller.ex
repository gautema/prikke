defmodule PrikkeWeb.Api.EndpointController do
  use PrikkeWeb.Api.ApiController
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Endpoints
  alias Prikke.Endpoints.Endpoint
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Endpoints"])
  security([%{"bearerAuth" => []}])

  operation(:index,
    summary: "List all endpoints",
    description: "Returns all inbound webhook endpoints for the authenticated organization",
    responses: [
      ok: {"Endpoints list", "application/json", Schemas.EndpointsResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.ErrorResponse}
    ]
  )

  def index(conn, _params) do
    org = conn.assigns.current_organization
    endpoints = Endpoints.list_endpoints(org)
    json(conn, %{data: Enum.map(endpoints, &endpoint_json(conn, &1))})
  end

  operation(:show,
    summary: "Get an endpoint",
    description: "Returns a single inbound webhook endpoint by ID",
    parameters: [
      id: [in: :path, type: :string, description: "Endpoint ID", required: true]
    ],
    responses: [
      ok: {"Endpoint", "application/json", Schemas.EndpointResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    org = conn.assigns.current_organization

    case Endpoints.get_endpoint(org, id) do
      nil -> {:error, :not_found}
      endpoint -> json(conn, %{data: endpoint_json(conn, endpoint)})
    end
  end

  operation(:create,
    summary: "Create an endpoint",
    description: "Creates a new inbound webhook endpoint",
    request_body: {"Endpoint parameters", "application/json", Schemas.EndpointRequest},
    responses: [
      created: {"Endpoint created", "application/json", Schemas.EndpointResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def create(conn, params) do
    endpoint_params = params["endpoint"] || params
    endpoint_params = normalize_forward_urls(endpoint_params)
    org = conn.assigns.current_organization

    api_key_name = conn.assigns[:api_key_name]

    case Endpoints.create_endpoint(org, endpoint_params, api_key_name: api_key_name) do
      {:ok, endpoint} ->
        conn
        |> put_status(:created)
        |> json(%{data: endpoint_json(conn, endpoint)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  operation(:update,
    summary: "Update an endpoint",
    description: "Updates an existing inbound webhook endpoint",
    parameters: [
      id: [in: :path, type: :string, description: "Endpoint ID", required: true]
    ],
    request_body: {"Endpoint parameters", "application/json", Schemas.EndpointRequest},
    responses: [
      ok: {"Endpoint updated", "application/json", Schemas.EndpointResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    endpoint_params = params["endpoint"] || Map.drop(params, ["id"])
    endpoint_params = normalize_forward_urls(endpoint_params)
    org = conn.assigns.current_organization
    api_key_name = conn.assigns[:api_key_name]

    case Endpoints.get_endpoint(org, id) do
      nil ->
        {:error, :not_found}

      endpoint ->
        case Endpoints.update_endpoint(org, endpoint, endpoint_params, api_key_name: api_key_name) do
          {:ok, endpoint} -> json(conn, %{data: endpoint_json(conn, endpoint)})
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  operation(:delete,
    summary: "Delete an endpoint",
    description: "Deletes an endpoint and all its inbound events",
    parameters: [
      id: [in: :path, type: :string, description: "Endpoint ID", required: true]
    ],
    responses: [
      no_content: "Endpoint deleted",
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def delete(conn, %{"id" => id}) do
    org = conn.assigns.current_organization
    api_key_name = conn.assigns[:api_key_name]

    case Endpoints.get_endpoint(org, id) do
      nil ->
        {:error, :not_found}

      endpoint ->
        case Endpoints.delete_endpoint(org, endpoint, api_key_name: api_key_name) do
          {:ok, _endpoint} -> send_resp(conn, :no_content, "")
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  operation(:events,
    summary: "List inbound events",
    description: "Returns the inbound event history for an endpoint",
    parameters: [
      endpoint_id: [in: :path, type: :string, description: "Endpoint ID", required: true],
      limit: [in: :query, type: :integer, description: "Maximum results (1-100, default 50)"]
    ],
    responses: [
      ok: {"Events", "application/json", Schemas.InboundEventsResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def events(conn, params) do
    org = conn.assigns.current_organization
    id = params["endpoint_id"]
    limit = parse_limit(params["limit"], 50)

    case Endpoints.get_endpoint(org, id) do
      nil ->
        {:error, :not_found}

      endpoint ->
        events = Endpoints.list_inbound_events(endpoint, limit: limit)
        json(conn, %{data: Enum.map(events, &event_json/1)})
    end
  end

  operation(:replay,
    summary: "Replay an inbound event",
    description: "Creates new forwarding executions for an existing inbound event",
    parameters: [
      endpoint_id: [in: :path, type: :string, description: "Endpoint ID", required: true],
      event_id: [in: :path, type: :string, description: "Event ID", required: true]
    ],
    responses: [
      accepted: {"Event replayed", "application/json", Schemas.ReplayResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  def replay(conn, %{"endpoint_id" => endpoint_id, "event_id" => event_id}) do
    org = conn.assigns.current_organization

    case Endpoints.get_endpoint(org, endpoint_id) do
      nil ->
        {:error, :not_found}

      endpoint ->
        event = Endpoints.get_inbound_event!(endpoint, event_id)

        case Endpoints.replay_event(endpoint, event) do
          {:ok, executions} ->
            conn
            |> put_status(:accepted)
            |> json(%{
              data: %{
                executions:
                  Enum.map(executions, fn exec ->
                    %{
                      execution_id: exec.id,
                      status: exec.status,
                      scheduled_for: exec.scheduled_for
                    }
                  end)
              },
              message: "Event replayed to #{length(executions)} destination(s)"
            })

          {:error, :no_tasks} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: "no_tasks",
                message: "Event has no linked tasks to replay"
              }
            })

          {:error, :task_deleted} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                code: "task_deleted",
                message: "All linked tasks have been deleted"
              }
            })
        end
    end
  end

  # JSON serialization helpers

  defp endpoint_json(conn, %Endpoint{} = e) do
    host = conn.host || "runlater.eu"

    %{
      id: e.id,
      name: e.name,
      slug: e.slug,
      inbound_url: "https://#{host}/in/#{e.slug}",
      forward_urls: e.forward_urls,
      enabled: e.enabled,
      retry_attempts: e.retry_attempts,
      use_queue: e.use_queue,
      notify_on_failure: e.notify_on_failure,
      notify_on_recovery: e.notify_on_recovery,
      on_failure_url: e.on_failure_url,
      on_recovery_url: e.on_recovery_url,
      forward_headers: e.forward_headers,
      forward_body: e.forward_body,
      forward_method: e.forward_method,
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end

  defp event_json(event) do
    status =
      case Map.get(event, :tasks, []) do
        [] -> nil
        tasks -> Endpoints.aggregate_task_statuses(tasks)
      end

    %{
      id: event.id,
      method: event.method,
      source_ip: event.source_ip,
      received_at: event.received_at,
      task_ids: event.task_ids,
      status: status
    }
  end

  defp normalize_forward_urls(params) do
    cond do
      is_list(params["forward_urls"]) -> params
      is_binary(params["forward_url"]) -> Map.put(params, "forward_urls", [params["forward_url"]])
      true -> params
    end
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
