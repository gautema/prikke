defmodule Prikke.Audit do
  @moduledoc """
  The Audit context.
  Handles audit logging for tracking changes to resources.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo
  alias Prikke.Audit.AuditLog
  alias Prikke.Accounts.{User, Organization, Scope}

  @doc """
  Logs an action performed by a user.
  """
  def log(%Scope{user: %User{} = user}, action, resource_type, resource_id, opts \\ []) do
    organization_id = opts[:organization_id]
    changes = opts[:changes] || %{}
    metadata = opts[:metadata] || %{}

    create_log(%{
      actor_id: user.id,
      actor_type: "user",
      action: to_string(action),
      resource_type: to_string(resource_type),
      resource_id: resource_id,
      organization_id: organization_id,
      changes: changes,
      metadata: metadata
    })
  end

  @doc """
  Logs an action performed via API key.
  """
  def log_api(api_key_name, action, resource_type, resource_id, opts \\ []) do
    organization_id = opts[:organization_id]
    changes = opts[:changes] || %{}
    metadata = Map.merge(opts[:metadata] || %{}, %{"api_key_name" => api_key_name})

    create_log(%{
      actor_id: nil,
      actor_type: "api",
      action: to_string(action),
      resource_type: to_string(resource_type),
      resource_id: resource_id,
      organization_id: organization_id,
      changes: changes,
      metadata: metadata
    })
  end

  @doc """
  Logs an action performed by the system.
  """
  def log_system(action, resource_type, resource_id, opts \\ []) do
    organization_id = opts[:organization_id]
    changes = opts[:changes] || %{}
    metadata = opts[:metadata] || %{}

    create_log(%{
      actor_id: nil,
      actor_type: "system",
      action: to_string(action),
      resource_type: to_string(resource_type),
      resource_id: resource_id,
      organization_id: organization_id,
      changes: changes,
      metadata: metadata
    })
  end

  defp create_log(attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists audit logs for an organization.
  """
  def list_organization_logs(%Organization{} = org, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(a in AuditLog,
      where: a.organization_id == ^org.id,
      order_by: [desc: a.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:actor]
    )
    |> Repo.all()
  end

  @doc """
  Lists all audit logs (for superadmin).
  """
  def list_all_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(a in AuditLog,
      order_by: [desc: a.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:actor, :organization]
    )
    |> Repo.all()
  end

  @doc """
  Lists audit logs for a specific resource.
  """
  def list_resource_logs(resource_type, resource_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(a in AuditLog,
      where: a.resource_type == ^to_string(resource_type) and a.resource_id == ^resource_id,
      order_by: [desc: a.inserted_at],
      limit: ^limit,
      preload: [:actor]
    )
    |> Repo.all()
  end

  @doc """
  Counts audit logs for an organization.
  """
  def count_organization_logs(%Organization{} = org) do
    from(a in AuditLog, where: a.organization_id == ^org.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Computes the changes between old and new values for logging.
  Only includes fields that actually changed.
  """
  def compute_changes(old_map, new_map, fields) when is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      old_val = Map.get(old_map, field)
      new_val = Map.get(new_map, field)

      if old_val != new_val do
        Map.put(acc, to_string(field), %{"from" => format_value(old_val), "to" => format_value(new_val)})
      else
        acc
      end
    end)
  end

  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_value(val) when is_binary(val) and byte_size(val) > 500, do: String.slice(val, 0, 500) <> "..."
  defp format_value(val), do: val

  @doc """
  Formats an audit log action for display.
  """
  def format_action("created"), do: "Created"
  def format_action("updated"), do: "Updated"
  def format_action("deleted"), do: "Deleted"
  def format_action("enabled"), do: "Enabled"
  def format_action("disabled"), do: "Disabled"
  def format_action("triggered"), do: "Triggered manually"
  def format_action("retried"), do: "Retried"
  def format_action("upgraded"), do: "Upgraded to Pro"
  def format_action("downgraded"), do: "Downgraded to Free"
  def format_action("invited"), do: "Invited member"
  def format_action("removed"), do: "Removed member"
  def format_action("role_changed"), do: "Changed role"
  def format_action("api_key_created"), do: "Created API key"
  def format_action("api_key_deleted"), do: "Deleted API key"
  def format_action(action), do: String.capitalize(action)

  @doc """
  Formats a resource type for display.
  """
  def format_resource_type("organization"), do: "Organization"
  def format_resource_type("job"), do: "Job"
  def format_resource_type("execution"), do: "Execution"
  def format_resource_type("membership"), do: "Member"
  def format_resource_type("invite"), do: "Invite"
  def format_resource_type("api_key"), do: "API Key"
  def format_resource_type(type), do: String.capitalize(type)
end
