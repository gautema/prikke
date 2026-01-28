defmodule PrikkeWeb.UserRegistrationController do
  use PrikkeWeb, :controller

  alias Prikke.Accounts
  alias Prikke.Accounts.User

  plug :put_layout, false
  plug :assign_hide_header

  defp assign_hide_header(conn, _opts), do: assign(conn, :hide_header, true)

  def new(conn, _params) do
    changeset = Accounts.change_user_email(%User{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        # Create a personal organization for the new user
        org_name = user.email |> String.split("@") |> hd() |> String.capitalize()
        Accounts.create_organization(user, %{name: "#{org_name}'s Org"})

        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        conn
        |> put_flash(
          :info,
          "An email was sent to #{user.email}, please access it to confirm your account."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end
end
