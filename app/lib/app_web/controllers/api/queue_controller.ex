defmodule PrikkeWeb.Api.QueueController do
  @moduledoc """
  API controller for queue management (pause/resume/list).
  """
  use PrikkeWeb.Api.ApiController
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Queues
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Queues"])
  security([%{"bearerAuth" => []}])

  operation(:index,
    summary: "List queues",
    description: "Returns queues for the authenticated organization with their pause status.",
    responses: [
      ok: {"Queues list", "application/json", Schemas.QueuesResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.ErrorResponse}
    ]
  )

  def index(conn, _params) do
    org = conn.assigns.current_organization
    queues = Queues.list_queues_with_status(org)

    json(conn, %{
      data:
        Enum.map(queues, fn {name, status} ->
          %{name: name, paused: status == :paused}
        end)
    })
  end

  operation(:pause,
    summary: "Pause a queue",
    description:
      "Pauses a queue. Workers will skip pending executions in this queue until resumed.",
    parameters: [
      name: [in: :path, type: :string, description: "Queue name", required: true]
    ],
    responses: [
      ok: {"Queue paused", "application/json", Schemas.QueueResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.ErrorResponse}
    ]
  )

  def pause(conn, %{"name" => name}) do
    org = conn.assigns.current_organization

    case Queues.pause_queue(org, name) do
      {:ok, _queue} ->
        json(conn, %{data: %{name: name, paused: true}, message: "Queue \"#{name}\" paused"})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  operation(:resume,
    summary: "Resume a queue",
    description:
      "Resumes a paused queue. Workers will start processing pending executions again.",
    parameters: [
      name: [in: :path, type: :string, description: "Queue name", required: true]
    ],
    responses: [
      ok: {"Queue resumed", "application/json", Schemas.QueueResponse},
      unauthorized: {"Unauthorized", "application/json", Schemas.ErrorResponse}
    ]
  )

  def resume(conn, %{"name" => name}) do
    org = conn.assigns.current_organization

    case Queues.resume_queue(org, name) do
      {:ok, _queue} ->
        json(conn, %{data: %{name: name, paused: false}, message: "Queue \"#{name}\" resumed"})

      :ok ->
        json(conn, %{data: %{name: name, paused: false}, message: "Queue \"#{name}\" resumed"})

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
