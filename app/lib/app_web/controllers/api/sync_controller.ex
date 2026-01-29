defmodule PrikkeWeb.Api.SyncController do
  @moduledoc """
  Declarative job synchronization endpoint.

  PUT /api/sync

  Allows users to declare their desired job state and have the system
  reconcile to match. This is ideal for CI/CD pipelines where job
  definitions are stored in code.

  ## Request Body

  ```json
  {
    "jobs": [
      {
        "name": "Daily cleanup",
        "url": "https://example.com/cleanup",
        "method": "POST",
        "schedule_type": "cron",
        "cron_expression": "0 0 * * *"
      }
    ],
    "delete_removed": false
  }
  ```

  ## Behavior

  - Jobs are matched by `name` (unique per organization)
  - If a job with that name exists, it's updated
  - If it doesn't exist, it's created
  - If `delete_removed: true`, jobs not in the list are deleted
  - Returns a summary of changes made
  """
  use PrikkeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Jobs
  alias Prikke.Repo
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Sync"])
  security([%{"bearerAuth" => []}])

  operation(:sync,
    summary: "Sync jobs declaratively",
    description: """
    Declarative job synchronization. Jobs are matched by name:
    - If a job exists with that name, it's updated
    - If no job exists, it's created
    - If `delete_removed: true`, jobs not in the list are deleted

    Ideal for CI/CD pipelines where job definitions are stored in code.
    """,
    request_body: {"Sync request", "application/json", Schemas.SyncRequest},
    responses: [
      ok: {"Sync result", "application/json", Schemas.SyncResponse},
      bad_request: {"Bad request", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def sync(conn, %{"jobs" => jobs_params} = params) when is_list(jobs_params) do
    org = conn.assigns.current_organization
    delete_removed = params["delete_removed"] == true

    result =
      Repo.transaction(fn ->
        sync_jobs(org, jobs_params, delete_removed)
      end)

    case result do
      {:ok, summary} ->
        json(conn, %{
          data: summary,
          message: format_summary_message(summary)
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sync(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "bad_request", message: "Request body must include 'jobs' array"}})
  end

  defp sync_jobs(org, jobs_params, delete_removed) do
    existing_jobs = Jobs.list_jobs(org) |> Map.new(&{&1.name, &1})
    declared_names = MapSet.new(jobs_params, & &1["name"])

    # Process declared jobs (create or update)
    {created, updated, errors} =
      Enum.reduce(jobs_params, {[], [], []}, fn job_params, {created, updated, errors} ->
        name = job_params["name"]

        if is_nil(name) or name == "" do
          {created, updated, [%{name: name, error: "name is required"} | errors]}
        else
          case Map.get(existing_jobs, name) do
            nil ->
              # Create new job
              case Jobs.create_job(org, job_params) do
                {:ok, job} ->
                  {[job.name | created], updated, errors}

                {:error, changeset} ->
                  {created, updated,
                   [%{name: name, error: format_changeset_error(changeset)} | errors]}
              end

            existing_job ->
              # Update existing job
              case Jobs.update_job(org, existing_job, job_params) do
                {:ok, _job} ->
                  {created, [name | updated], errors}

                {:error, changeset} ->
                  {created, updated,
                   [%{name: name, error: format_changeset_error(changeset)} | errors]}
              end
          end
        end
      end)

    # Handle deletion of removed jobs
    deleted =
      if delete_removed do
        existing_jobs
        |> Enum.filter(fn {name, _job} -> not MapSet.member?(declared_names, name) end)
        |> Enum.reduce([], fn {name, job}, deleted ->
          case Jobs.delete_job(org, job) do
            {:ok, _} -> [name | deleted]
            {:error, _} -> deleted
          end
        end)
      else
        []
      end

    # If there are errors, rollback
    if errors != [] do
      Repo.rollback(%{errors: Enum.reverse(errors)})
    else
      %{
        created: Enum.reverse(created),
        updated: Enum.reverse(updated),
        deleted: Enum.reverse(deleted),
        created_count: length(created),
        updated_count: length(updated),
        deleted_count: length(deleted)
      }
    end
  end

  defp format_changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  defp format_summary_message(summary) do
    parts = []

    parts =
      if summary.created_count > 0, do: ["#{summary.created_count} created" | parts], else: parts

    parts =
      if summary.updated_count > 0, do: ["#{summary.updated_count} updated" | parts], else: parts

    parts =
      if summary.deleted_count > 0, do: ["#{summary.deleted_count} deleted" | parts], else: parts

    case parts do
      [] -> "No changes"
      _ -> "Sync complete: " <> Enum.join(Enum.reverse(parts), ", ")
    end
  end
end
