defmodule PrikkeWeb.OrganizationController do
  use PrikkeWeb, :controller

  import Phoenix.Component, only: [to_form: 1]

  alias Prikke.Accounts
  alias Prikke.Jobs
  alias Prikke.Executions
  alias Prikke.Audit

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    organizations = Accounts.list_user_organizations(user)
    render(conn, :index, organizations: organizations)
  end

  def new(conn, _params) do
    changeset = Accounts.change_organization(%Accounts.Organization{})
    render(conn, :new, form: to_form(changeset))
  end

  def create(conn, %{"organization" => org_params}) do
    user = conn.assigns.current_scope.user

    case Accounts.create_organization(user, org_params) do
      {:ok, organization} ->
        conn
        |> put_flash(:info, "Organization created successfully.")
        |> put_session(:current_organization_id, organization.id)
        |> redirect(to: ~p"/")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, form: to_form(changeset))
    end
  end

  def switch(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    case Accounts.get_membership(%Accounts.Organization{id: id}, user) do
      nil ->
        conn
        |> put_flash(:error, "Organization not found.")
        |> redirect(to: ~p"/")

      _membership ->
        conn
        |> put_session(:current_organization_id, id)
        |> put_flash(:info, "Switched organization.")
        |> redirect(to: ~p"/")
    end
  end

  def edit(conn, _params) do
    organization = conn.assigns.current_organization

    if organization do
      changeset = Accounts.change_organization(organization)
      tier_limits = Jobs.get_tier_limits(organization.tier)
      monthly_executions = Executions.count_current_month_executions(organization)

      render(conn, :edit,
        organization: organization,
        form: to_form(changeset),
        monthly_executions: monthly_executions,
        monthly_limit: tier_limits.max_monthly_executions
      )
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end

  def update(conn, %{"organization" => org_params}) do
    organization = conn.assigns.current_organization

    case Accounts.update_organization(organization, org_params, scope: conn.assigns.current_scope) do
      {:ok, _organization} ->
        conn
        |> put_flash(:info, "Organization updated successfully.")
        |> redirect(to: ~p"/organizations/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, organization: organization, form: to_form(changeset))
    end
  end

  def members(conn, _params) do
    organization = conn.assigns.current_organization
    user = conn.assigns.current_scope.user

    if organization do
      members = Accounts.list_organization_members(organization)
      invites = Accounts.list_organization_invites(organization)
      current_membership = Accounts.get_membership(organization, user)

      render(conn, :members,
        organization: organization,
        members: members,
        invites: invites,
        current_membership: current_membership
      )
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end

  def update_member_role(conn, %{"id" => membership_id, "role" => role}) do
    organization = conn.assigns.current_organization
    user = conn.assigns.current_scope.user

    with true <- role in ["admin", "member"],
         current_membership when not is_nil(current_membership) <-
           Accounts.get_membership(organization, user),
         true <- current_membership.role in ["owner", "admin"],
         membership when not is_nil(membership) <- Accounts.get_membership_by_id(membership_id),
         true <- membership.organization_id == organization.id,
         false <- membership.role == "owner" do
      case Accounts.update_membership_role(membership, role) do
        {:ok, _} ->
          conn
          |> put_flash(:info, "Role updated successfully.")
          |> redirect(to: ~p"/organizations/members")

        {:error, _} ->
          conn
          |> put_flash(:error, "Could not update role.")
          |> redirect(to: ~p"/organizations/members")
      end
    else
      _ ->
        conn
        |> put_flash(:error, "You don't have permission to change this role.")
        |> redirect(to: ~p"/organizations/members")
    end
  end

  def notifications(conn, _params) do
    organization = conn.assigns.current_organization

    if organization do
      changeset = Accounts.change_notification_settings(organization)
      render(conn, :notifications, organization: organization, form: to_form(changeset))
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end

  def update_notifications(conn, %{"organization" => notification_params}) do
    organization = conn.assigns.current_organization

    case Accounts.update_notification_settings(organization, notification_params, scope: conn.assigns.current_scope) do
      {:ok, _organization} ->
        conn
        |> put_flash(:info, "Notification settings updated.")
        |> redirect(to: ~p"/organizations/notifications")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :notifications, organization: organization, form: to_form(changeset))
    end
  end

  def upgrade(conn, _params) do
    organization = conn.assigns.current_organization

    if organization.tier == "free" do
      case Accounts.upgrade_organization_to_pro(organization) do
        {:ok, _organization} ->
          conn
          |> put_flash(
            :info,
            "You've been upgraded to Pro! Our team will reach out to set up billing."
          )
          |> redirect(to: ~p"/organizations/settings")

        {:error, _} ->
          conn
          |> put_flash(:error, "Could not upgrade. Please try again.")
          |> redirect(to: ~p"/organizations/settings")
      end
    else
      conn
      |> put_flash(:info, "You're already on the Pro plan.")
      |> redirect(to: ~p"/organizations/settings")
    end
  end

  def api_keys(conn, _params) do
    organization = conn.assigns.current_organization

    if organization do
      api_keys = Accounts.list_organization_api_keys(organization)

      render(conn, :api_keys,
        organization: organization,
        api_keys: api_keys,
        form: to_form(%{}),
        new_key: nil
      )
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end

  def create_api_key(conn, %{"api_key" => %{"name" => name}}) do
    organization = conn.assigns.current_organization
    user = conn.assigns.current_scope.user

    case Accounts.create_api_key(organization, user, %{name: name}, scope: conn.assigns.current_scope) do
      {:ok, api_key, raw_secret} ->
        api_keys = Accounts.list_organization_api_keys(organization)
        full_key = "#{api_key.key_id}.#{raw_secret}"

        conn
        |> put_flash(:info, "API key created successfully.")
        |> render(:api_keys,
          organization: organization,
          api_keys: api_keys,
          form: to_form(%{}),
          new_key: full_key
        )

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not create API key.")
        |> redirect(to: ~p"/organizations/api-keys")
    end
  end

  def delete_api_key(conn, %{"id" => id}) do
    organization = conn.assigns.current_organization

    case Accounts.get_api_key(organization, id) do
      nil ->
        conn
        |> put_flash(:error, "API key not found.")
        |> redirect(to: ~p"/organizations/api-keys")

      api_key ->
        case Accounts.delete_api_key(api_key, scope: conn.assigns.current_scope) do
          {:ok, _} ->
            conn
            |> put_flash(:info, "API key revoked.")
            |> redirect(to: ~p"/organizations/api-keys")

          {:error, _} ->
            conn
            |> put_flash(:error, "Could not revoke API key.")
            |> redirect(to: ~p"/organizations/api-keys")
        end
    end
  end

  def audit(conn, _params) do
    organization = conn.assigns.current_organization
    user = conn.assigns.current_scope.user

    if organization do
      # Check if user is owner or admin
      membership = Accounts.get_membership(organization, user)

      if membership && membership.role in ["owner", "admin"] do
        audit_logs = Audit.list_organization_logs(organization, limit: 50)
        render(conn, :audit, organization: organization, audit_logs: audit_logs)
      else
        conn
        |> put_flash(:error, "You need to be an admin to view audit logs.")
        |> redirect(to: ~p"/organizations/settings")
      end
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end

  def regenerate_webhook_secret(conn, _params) do
    organization = conn.assigns.current_organization
    user = conn.assigns.current_scope.user

    if organization do
      # Check if user is owner or admin
      membership = Accounts.get_membership(organization, user)

      if membership && membership.role in ["owner", "admin"] do
        case Accounts.regenerate_webhook_secret(organization, scope: conn.assigns.current_scope) do
          {:ok, _updated_org} ->
            conn
            |> put_flash(:info, "Webhook secret regenerated successfully.")
            |> redirect(to: ~p"/organizations/api-keys")

          {:error, _} ->
            conn
            |> put_flash(:error, "Could not regenerate webhook secret.")
            |> redirect(to: ~p"/organizations/api-keys")
        end
      else
        conn
        |> put_flash(:error, "You need to be an admin to regenerate the webhook secret.")
        |> redirect(to: ~p"/organizations/api-keys")
      end
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end
end
