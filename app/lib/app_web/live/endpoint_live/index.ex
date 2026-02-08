defmodule PrikkeWeb.EndpointLive.Index do
  use PrikkeWeb, :live_view

  alias Prikke.Endpoints

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      if connected?(socket) do
        Endpoints.subscribe_endpoints(org)
      end

      endpoints = Endpoints.list_endpoints(org)
      host = Application.get_env(:app, PrikkeWeb.Endpoint)[:url][:host] || "runlater.eu"

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Endpoints")
       |> assign(:endpoints, endpoints)
       |> assign(:host, host)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_info({:endpoint_created, endpoint}, socket) do
    endpoints = [endpoint | socket.assigns.endpoints]
    {:noreply, assign(socket, :endpoints, endpoints)}
  end

  def handle_info({:endpoint_updated, endpoint}, socket) do
    endpoints =
      Enum.map(socket.assigns.endpoints, fn e -> if e.id == endpoint.id, do: endpoint, else: e end)

    {:noreply, assign(socket, :endpoints, endpoints)}
  end

  def handle_info({:endpoint_deleted, endpoint}, socket) do
    endpoints = Enum.reject(socket.assigns.endpoints, fn e -> e.id == endpoint.id end)
    {:noreply, assign(socket, :endpoints, endpoints)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    endpoint = Endpoints.get_endpoint!(socket.assigns.organization, id)
    {:ok, _} = Endpoints.delete_endpoint(socket.assigns.organization, endpoint, scope: socket.assigns.current_scope)
    {:noreply, put_flash(socket, :info, "Endpoint deleted")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    org = socket.assigns.organization
    endpoint = Endpoints.get_endpoint!(org, id)
    {:ok, _} = Endpoints.update_endpoint(org, endpoint, %{enabled: !endpoint.enabled}, scope: socket.assigns.current_scope)
    {:noreply, socket}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mb-4">
        <.link
          navigate={~p"/dashboard"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Dashboard
        </.link>
      </div>

      <div class="flex justify-between items-center mb-6 sm:mb-8 pl-1 sm:pl-0">
        <div>
          <h1 class="text-xl sm:text-2xl font-bold text-slate-900">Endpoints</h1>
          <p class="text-slate-500 mt-1 text-sm">Receive webhooks and forward them to your app</p>
        </div>
        <.link
          navigate={~p"/endpoints/new"}
          class="text-sm font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-3 sm:px-4 py-2 rounded-md transition-colors no-underline whitespace-nowrap"
        >
          New Endpoint
        </.link>
      </div>

      <%= if @endpoints == [] do %>
        <div class="glass-card rounded-2xl p-8 sm:p-12 text-center">
          <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-arrow-down-tray" class="w-6 h-6 text-slate-400" />
          </div>
          <h3 class="text-lg font-medium text-slate-900 mb-2">No endpoints yet</h3>
          <p class="text-slate-500 mb-6">
            Create an endpoint to start receiving webhooks from external services like Stripe or GitHub.
          </p>
          <.link navigate={~p"/endpoints/new"} class="text-emerald-600 font-medium hover:underline">
            Create an endpoint
          </.link>
        </div>
      <% else %>
        <div class="glass-card rounded-2xl divide-y divide-slate-200/60">
          <%= for endpoint <- @endpoints do %>
            <div class="px-4 sm:px-6 py-5">
              <div class="flex items-start sm:items-center justify-between gap-3">
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 sm:gap-3 flex-wrap">
                    <span class={[
                      "w-2.5 h-2.5 rounded-full shrink-0",
                      if(endpoint.enabled, do: "bg-emerald-500", else: "bg-slate-300")
                    ]} />
                    <.link
                      navigate={~p"/endpoints/#{endpoint.id}"}
                      class="font-medium text-slate-900 hover:text-emerald-600 break-all sm:truncate"
                    >
                      {endpoint.name}
                    </.link>
                    <span class={[
                      "text-xs font-medium px-2 py-0.5 rounded",
                      if(endpoint.enabled, do: "bg-emerald-100 text-emerald-700", else: "bg-slate-100 text-slate-600")
                    ]}>
                      {if endpoint.enabled, do: "Active", else: "Disabled"}
                    </span>
                  </div>
                  <div class="text-xs sm:text-sm text-slate-400 mt-1 font-mono truncate">
                    https://{@host}/in/{endpoint.slug}
                  </div>
                </div>
                <div class="flex items-center gap-2 sm:gap-3 shrink-0">
                  <button
                    type="button"
                    phx-click="toggle"
                    phx-value-id={endpoint.id}
                    class={[
                      "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:ring-offset-2",
                      endpoint.enabled && "bg-emerald-600",
                      !endpoint.enabled && "bg-slate-200"
                    ]}
                  >
                    <span class={[
                      "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                      endpoint.enabled && "translate-x-5",
                      !endpoint.enabled && "translate-x-0"
                    ]} />
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={endpoint.id}
                    data-confirm="Are you sure you want to delete this endpoint and all its events?"
                    class="text-slate-400 hover:text-red-600 p-1"
                  >
                    <.icon name="hero-trash" class="w-5 h-5" />
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
