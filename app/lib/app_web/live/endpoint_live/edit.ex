defmodule PrikkeWeb.EndpointLive.Edit do
  use PrikkeWeb, :live_view

  alias Prikke.Endpoints

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      endpoint = Endpoints.get_endpoint!(org, id)
      changeset = Endpoints.change_endpoint(endpoint)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:endpoint, endpoint)
       |> assign(:page_title, "Edit #{endpoint.name}")
       |> assign_form(changeset)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket) do
    changeset =
      socket.assigns.endpoint
      |> Endpoints.change_endpoint(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"endpoint" => params}, socket) do
    org = socket.assigns.organization
    endpoint = socket.assigns.endpoint

    case Endpoints.update_endpoint(org, endpoint, params, scope: socket.assigns.current_scope) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Endpoint updated")
         |> push_navigate(to: ~p"/endpoints/#{updated.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update endpoint")
         |> assign_form(Map.put(changeset, :action, :validate))}
    end
  end

  defp get_organization(socket, session) do
    user = socket.assigns.current_scope.user
    org_id = session["current_organization_id"]

    if org_id do
      Prikke.Accounts.get_organization_for_user(user, org_id)
    else
      case Prikke.Accounts.list_user_organizations(user) do
        [org | _] -> org
        [] -> nil
      end
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mb-4">
        <.link
          navigate={~p"/endpoints/#{@endpoint.id}"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to {@endpoint.name}
        </.link>
      </div>

      <h1 class="text-xl sm:text-2xl font-bold text-slate-900 mb-6">Edit Endpoint</h1>

      <div class="glass-card rounded-2xl p-6">
        <.form for={@form} id="endpoint-form" phx-change="validate" phx-submit="save" class="space-y-6">
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:forward_url]} type="text" label="Forward URL" />

          <div class="pt-4">
            <button
              type="submit"
              class="w-full sm:w-auto font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-6 py-2.5 rounded-md transition-colors"
            >
              Save Changes
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
