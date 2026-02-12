defmodule PrikkeWeb.EndpointLive.New do
  use PrikkeWeb, :live_view

  alias Prikke.Endpoints
  alias Prikke.Endpoints.Endpoint

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      changeset = Endpoints.change_new_endpoint(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "New Endpoint")
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
      %Endpoint{}
      |> Endpoints.change_endpoint(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"endpoint" => params}, socket) do
    case Endpoints.create_endpoint(socket.assigns.organization, params,
           scope: socket.assigns.current_scope
         ) do
      {:ok, endpoint} ->
        {:noreply,
         socket
         |> put_flash(:info, "Endpoint created successfully")
         |> push_navigate(to: ~p"/endpoints/#{endpoint.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create endpoint")
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
          navigate={~p"/endpoints"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Endpoints
        </.link>
      </div>

      <h1 class="text-xl sm:text-2xl font-bold text-slate-900 mb-6">Create New Endpoint</h1>

      <div class="glass-card rounded-2xl p-6">
        <.form
          for={@form}
          id="endpoint-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            placeholder="Stripe webhooks"
          />

          <.input
            field={@form[:forward_url]}
            type="text"
            label="Forward URL"
            placeholder="https://myapp.com/webhooks/stripe"
          />

          <p class="text-sm text-slate-500">
            Incoming webhooks will be forwarded to this URL with the original method, headers, and body.
          </p>

          <.input
            field={@form[:retry_attempts]}
            type="number"
            label="Retry attempts"
            min="0"
            max="10"
          />
          <p class="text-sm text-slate-500 -mt-4">
            Number of times to retry forwarding if it fails (0-10).
          </p>

          <div class="flex items-start gap-3">
            <.input
              field={@form[:use_queue]}
              type="checkbox"
              label="Use queue (serial execution)"
            />
          </div>
          <p class="text-sm text-slate-500 -mt-4">
            When enabled, events are forwarded one at a time. Disable for parallel forwarding when order doesn't matter.
          </p>

          <div class="pt-4">
            <button
              type="submit"
              class="w-full sm:w-auto font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-6 py-2.5 rounded-md transition-colors"
            >
              Create Endpoint
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
