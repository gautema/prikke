defmodule PrikkeWeb.Api.SyncController do
  @moduledoc """
  Declarative synchronization endpoint for jobs and monitors.

  PUT /api/sync

  Allows users to declare their desired state and have the system
  reconcile to match. This is ideal for CI/CD pipelines where
  definitions are stored in code.

  ## Request Body

  ```json
  {
    "jobs": [...],
    "monitors": [...],
    "delete_removed": false
  }
  ```

  ## Behavior

  - Resources are matched by `name` (unique per organization)
  - If a resource with that name exists, it's updated
  - If it doesn't exist, it's created
  - If `delete_removed: true`, resources not in the list are deleted
  - Returns a summary of changes made
  - At least one of `jobs` or `monitors` must be provided
  """
  use PrikkeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Prikke.Jobs
  alias Prikke.Monitors
  alias Prikke.Repo
  alias PrikkeWeb.Schemas

  action_fallback PrikkeWeb.Api.FallbackController

  tags(["Sync"])
  security([%{"bearerAuth" => []}])

  operation(:sync,
    summary: "Sync jobs and monitors declaratively",
    description: """
    Declarative synchronization. Resources are matched by name:
    - If a resource exists with that name, it's updated
    - If no resource exists, it's created
    - If `delete_removed: true`, resources not in the list are deleted

    At least one of `jobs` or `monitors` must be provided.
    Ideal for CI/CD pipelines where definitions are stored in code.
    """,
    request_body: {"Sync request", "application/json", Schemas.SyncRequest},
    responses: [
      ok: {"Sync result", "application/json", Schemas.SyncResponse},
      bad_request: {"Bad request", "application/json", Schemas.ErrorResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  def sync(conn, params) do
    jobs_params = params["jobs"]
    monitors_params = params["monitors"]

    has_jobs = is_list(jobs_params)
    has_monitors = is_list(monitors_params)

    if not has_jobs and not has_monitors do
      conn
      |> put_status(:bad_request)
      |> json(%{
        error: %{
          code: "bad_request",
          message: "Request body must include 'jobs' and/or 'monitors' array"
        }
      })
    else
      org = conn.assigns.current_organization
      api_key_name = conn.assigns[:api_key_name]
      delete_removed = params["delete_removed"] == true

      result =
        Repo.transaction(fn ->
          jobs_summary =
            if has_jobs do
              sync_jobs(org, jobs_params, delete_removed, api_key_name)
            else
              empty_summary()
            end

          monitors_summary =
            if has_monitors do
              sync_monitors(org, monitors_params, delete_removed)
            else
              empty_summary()
            end

          %{jobs: jobs_summary, monitors: monitors_summary}
        end)

      case result do
        {:ok, summary} ->
          # Include top-level job fields for backwards compatibility
          data =
            Map.merge(summary.jobs, %{
              jobs: summary.jobs,
              monitors: summary.monitors
            })

          json(conn, %{
            data: data,
            message: format_summary_message(summary)
          })

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp empty_summary do
    %{
      created: [],
      updated: [],
      deleted: [],
      created_count: 0,
      updated_count: 0,
      deleted_count: 0
    }
  end

  defp sync_jobs(org, jobs_params, delete_removed, api_key_name) do
    existing_jobs = Jobs.list_jobs(org) |> Map.new(&{&1.name, &1})
    declared_names = MapSet.new(jobs_params, & &1["name"])

    {created, updated, errors} =
      Enum.reduce(jobs_params, {[], [], []}, fn job_params, {created, updated, errors} ->
        name = job_params["name"]

        if is_nil(name) or name == "" do
          {created, updated, [%{name: name, error: "name is required"} | errors]}
        else
          case Map.get(existing_jobs, name) do
            nil ->
              case Jobs.create_job(org, job_params, api_key_name: api_key_name) do
                {:ok, job} ->
                  {[job.name | created], updated, errors}

                {:error, changeset} ->
                  {created, updated,
                   [%{name: name, error: format_changeset_error(changeset)} | errors]}
              end

            existing_job ->
              case Jobs.update_job(org, existing_job, job_params, api_key_name: api_key_name) do
                {:ok, _job} ->
                  {created, [name | updated], errors}

                {:error, changeset} ->
                  {created, updated,
                   [%{name: name, error: format_changeset_error(changeset)} | errors]}
              end
          end
        end
      end)

    deleted =
      if delete_removed do
        existing_jobs
        |> Enum.filter(fn {name, _job} -> not MapSet.member?(declared_names, name) end)
        |> Enum.reduce([], fn {name, job}, deleted ->
          case Jobs.delete_job(org, job, api_key_name: api_key_name) do
            {:ok, _} -> [name | deleted]
            {:error, _} -> deleted
          end
        end)
      else
        []
      end

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

  defp sync_monitors(org, monitors_params, delete_removed) do
    existing_monitors = Monitors.list_monitors(org) |> Map.new(&{&1.name, &1})
    declared_names = MapSet.new(monitors_params, & &1["name"])

    {created, updated, errors} =
      Enum.reduce(monitors_params, {[], [], []}, fn monitor_params, {created, updated, errors} ->
        name = monitor_params["name"]

        if is_nil(name) or name == "" do
          {created, updated, [%{name: name, error: "name is required"} | errors]}
        else
          case Map.get(existing_monitors, name) do
            nil ->
              case Monitors.create_monitor(org, monitor_params) do
                {:ok, monitor} ->
                  {[monitor.name | created], updated, errors}

                {:error, changeset} ->
                  {created, updated,
                   [%{name: name, error: format_changeset_error(changeset)} | errors]}
              end

            existing_monitor ->
              case Monitors.update_monitor(org, existing_monitor, monitor_params) do
                {:ok, _monitor} ->
                  {created, [name | updated], errors}

                {:error, changeset} ->
                  {created, updated,
                   [%{name: name, error: format_changeset_error(changeset)} | errors]}
              end
          end
        end
      end)

    deleted =
      if delete_removed do
        existing_monitors
        |> Enum.filter(fn {name, _monitor} -> not MapSet.member?(declared_names, name) end)
        |> Enum.reduce([], fn {name, monitor}, deleted ->
          case Monitors.delete_monitor(org, monitor) do
            {:ok, _} -> [name | deleted]
            {:error, _} -> deleted
          end
        end)
      else
        []
      end

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

  defp format_summary_message(%{jobs: jobs, monitors: monitors}) do
    parts = []

    total_created = jobs.created_count + monitors.created_count
    total_updated = jobs.updated_count + monitors.updated_count
    total_deleted = jobs.deleted_count + monitors.deleted_count

    parts = if total_created > 0, do: ["#{total_created} created" | parts], else: parts
    parts = if total_updated > 0, do: ["#{total_updated} updated" | parts], else: parts
    parts = if total_deleted > 0, do: ["#{total_deleted} deleted" | parts], else: parts

    case parts do
      [] -> "No changes"
      _ -> "Sync complete: " <> Enum.join(Enum.reverse(parts), ", ")
    end
  end
end
