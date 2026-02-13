defmodule PrikkeWeb.InviteController do
  use PrikkeWeb, :controller

  alias Prikke.Accounts
  alias Prikke.Audit

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    invites = Accounts.list_pending_invites_for_email(user.email)
    render(conn, :index, invites: invites)
  end

  def new(conn, _params) do
    render(conn, :new, changeset: %{})
  end

  def create(conn, %{"invite" => %{"email" => email, "role" => role}}) do
    organization = conn.assigns.current_organization
    user = conn.assigns.current_scope.user

    case Accounts.create_organization_invite(organization, user, %{email: email, role: role}) do
      {:ok, invite, raw_token} ->
        Accounts.deliver_organization_invite(
          invite,
          raw_token,
          &url(~p"/invites/#{&1}")
        )

        Audit.log(conn.assigns.current_scope, :invited, :invite, invite.id,
          organization_id: organization.id,
          metadata: %{"email" => email, "role" => role}
        )

        conn
        |> put_flash(:info, "Invitation sent to #{email}")
        |> redirect(to: ~p"/organizations/members")

      {:error, changeset} ->
        conn
        |> put_flash(:error, format_errors(changeset))
        |> redirect(to: ~p"/organizations/members")
    end
  end

  def show(conn, %{"token" => token}) do
    case Accounts.get_invite_by_token(token) do
      nil ->
        conn
        |> put_flash(:error, "Invite is invalid or has expired.")
        |> redirect(to: ~p"/")

      invite ->
        render(conn, :show, invite: invite, token: token)
    end
  end

  def accept(conn, %{"token" => token}) do
    user = conn.assigns[:current_scope] && conn.assigns.current_scope.user

    case Accounts.get_invite_by_token(token) do
      nil ->
        conn
        |> put_flash(:error, "Invite is invalid or has expired.")
        |> redirect(to: ~p"/")

      invite ->
        if user do
          accept_invite(conn, invite, user)
        else
          # Store invite token and redirect to register/login
          conn
          |> put_session(:pending_invite_token, token)
          |> put_flash(:info, "Please log in or create an account to accept the invitation.")
          |> redirect(to: ~p"/users/log-in")
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    organization = conn.assigns.current_organization

    invite = Accounts.list_organization_invites(organization) |> Enum.find(&(&1.id == id))

    if invite do
      Accounts.delete_invite(invite)

      Audit.log(conn.assigns.current_scope, :deleted, :invite, invite.id,
        organization_id: organization.id,
        metadata: %{"email" => invite.email}
      )

      conn
      |> put_flash(:info, "Invitation cancelled.")
      |> redirect(to: ~p"/organizations/members")
    else
      conn
      |> put_flash(:error, "Invitation not found.")
      |> redirect(to: ~p"/organizations/members")
    end
  end

  def accept_direct(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    invites = Accounts.list_pending_invites_for_email(user.email)
    invite = Enum.find(invites, &(&1.id == id))

    if invite do
      accept_invite(conn, invite, user)
    else
      conn
      |> put_flash(:error, "Invite not found or you don't have permission to accept it.")
      |> redirect(to: ~p"/invites")
    end
  end

  defp accept_invite(conn, invite, user) do
    case Accounts.accept_invite(invite, user) do
      {:ok, _membership} ->
        conn
        |> put_session(:current_organization_id, invite.organization_id)
        |> put_flash(:info, "You've joined #{invite.organization.name}!")
        |> redirect(to: ~p"/")

      {:error, :already_member} ->
        conn
        |> put_flash(:info, "You're already a member of this organization.")
        |> redirect(to: ~p"/")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not accept invitation. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
