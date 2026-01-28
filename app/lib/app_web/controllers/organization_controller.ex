defmodule PrikkeWeb.OrganizationController do
  use PrikkeWeb, :controller

  alias Prikke.Accounts

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    organizations = Accounts.list_user_organizations(user)
    render(conn, :index, organizations: organizations)
  end

  def new(conn, _params) do
    changeset = Accounts.change_organization(%Accounts.Organization{})
    render(conn, :new, changeset: changeset)
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
        render(conn, :new, changeset: changeset)
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
      render(conn, :edit, organization: organization, changeset: changeset)
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end

  def update(conn, %{"organization" => org_params}) do
    organization = conn.assigns.current_organization

    case Accounts.update_organization(organization, org_params) do
      {:ok, _organization} ->
        conn
        |> put_flash(:info, "Organization updated successfully.")
        |> redirect(to: ~p"/organizations/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, organization: organization, changeset: changeset)
    end
  end

  def members(conn, _params) do
    organization = conn.assigns.current_organization

    if organization do
      members = Accounts.list_organization_members(organization)
      invites = Accounts.list_organization_invites(organization)
      render(conn, :members, organization: organization, members: members, invites: invites)
    else
      conn
      |> put_flash(:error, "No organization selected.")
      |> redirect(to: ~p"/")
    end
  end
end
