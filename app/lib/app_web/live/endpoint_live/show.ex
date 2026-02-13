defmodule PrikkeWeb.EndpointLive.Show do
  use PrikkeWeb, :live_view

  alias Prikke.Endpoints

  @per_page 20

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      endpoint = Endpoints.get_endpoint(org, id)

      if is_nil(endpoint) do
        {:ok,
         socket
         |> put_flash(:error, "Endpoint not found")
         |> redirect(to: ~p"/endpoints")}
      else
        if connected?(socket) do
          Endpoints.subscribe_endpoints(org)
        end

        events = Endpoints.list_inbound_events(endpoint, limit: @per_page)
        total_events = Endpoints.count_inbound_events(endpoint)
        host = Application.get_env(:app, PrikkeWeb.Endpoint)[:url][:host] || "runlater.eu"
        inbound_url = "https://#{host}/in/#{endpoint.slug}"

        {:ok,
         socket
         |> assign(:organization, org)
         |> assign(:endpoint, endpoint)
         |> assign(:events, events)
         |> assign(:total_events, total_events)
         |> assign(:inbound_url, inbound_url)
         |> assign(:page_title, endpoint.name)
         |> assign(:menu_open, false)
         |> assign(:host, host)}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_info({:endpoint_updated, endpoint}, socket) do
    if endpoint.id == socket.assigns.endpoint.id do
      {:noreply, assign(socket, :endpoint, endpoint)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:endpoint_deleted, endpoint}, socket) do
    if endpoint.id == socket.assigns.endpoint.id do
      {:noreply,
       socket
       |> put_flash(:info, "Endpoint was deleted")
       |> push_navigate(to: ~p"/endpoints")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_menu", _, socket) do
    {:noreply, assign(socket, :menu_open, !socket.assigns.menu_open)}
  end

  def handle_event("close_menu", _, socket) do
    {:noreply, assign(socket, :menu_open, false)}
  end

  def handle_event("toggle", _, socket) do
    org = socket.assigns.organization
    endpoint = socket.assigns.endpoint

    {:ok, updated} =
      Endpoints.update_endpoint(org, endpoint, %{enabled: !endpoint.enabled},
        scope: socket.assigns.current_scope
      )

    {:noreply, assign(socket, :endpoint, updated)}
  end

  def handle_event("delete", _, socket) do
    org = socket.assigns.organization
    endpoint = socket.assigns.endpoint
    {:ok, _} = Endpoints.delete_endpoint(org, endpoint, scope: socket.assigns.current_scope)

    {:noreply,
     socket
     |> put_flash(:info, "Endpoint deleted")
     |> push_navigate(to: ~p"/endpoints")}
  end

  def handle_event("replay", %{"id" => event_id}, socket) do
    endpoint = socket.assigns.endpoint
    event = Endpoints.get_inbound_event!(endpoint, event_id)

    case Endpoints.replay_event(endpoint, event) do
      {:ok, _execution} ->
        current_loaded = max(length(socket.assigns.events), @per_page)
        events = Endpoints.list_inbound_events(endpoint, limit: current_loaded)
        total_events = Endpoints.count_inbound_events(endpoint)

        {:noreply,
         socket
         |> assign(:events, events)
         |> assign(:total_events, total_events)
         |> put_flash(:info, "Event replayed")}

      {:error, :no_execution} ->
        {:noreply, put_flash(socket, :error, "Cannot replay: no linked execution")}
    end
  end

  def handle_event("load_more", _, socket) do
    endpoint = socket.assigns.endpoint
    current_count = length(socket.assigns.events)

    more_events =
      Endpoints.list_inbound_events(endpoint,
        limit: @per_page,
        offset: current_count
      )

    {:noreply, assign(socket, :events, socket.assigns.events ++ more_events)}
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

  defp execution_status_badge("success"), do: "bg-emerald-100 text-emerald-700"
  defp execution_status_badge("failed"), do: "bg-red-100 text-red-700"
  defp execution_status_badge("timeout"), do: "bg-amber-100 text-amber-700"
  defp execution_status_badge("running"), do: "bg-blue-100 text-blue-700"
  defp execution_status_badge("pending"), do: "bg-slate-100 text-slate-600"
  defp execution_status_badge(_), do: "bg-slate-100 text-slate-600"

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

      <div class="flex justify-between items-center mb-6">
        <div class="flex items-center gap-3">
          <h1 class="text-xl sm:text-2xl font-bold text-slate-900">{@endpoint.name}</h1>
          <span class={[
            "text-xs font-medium px-2 py-0.5 rounded",
            if(@endpoint.enabled,
              do: "bg-emerald-100 text-emerald-700",
              else: "bg-slate-100 text-slate-600"
            )
          ]}>
            {if @endpoint.enabled, do: "Active", else: "Disabled"}
          </span>
        </div>

        <div class="flex items-center gap-2">
          <div id="endpoint-actions-menu" class="relative" phx-hook=".ClickOutside">
            <button
              type="button"
              phx-click="toggle_menu"
              class="p-2 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-md transition-colors"
            >
              <.icon name="hero-ellipsis-vertical" class="w-5 h-5" />
            </button>
            <%= if @menu_open do %>
              <div class="absolute right-0 top-full mt-1 w-40 bg-white rounded-lg shadow-lg border border-slate-200 py-1 z-50">
                <.link
                  navigate={~p"/endpoints/#{@endpoint.id}/edit"}
                  class="block w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50"
                >
                  Edit
                </.link>
                <button
                  type="button"
                  phx-click="toggle"
                  class="block w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50"
                >
                  {if @endpoint.enabled, do: "Disable", else: "Enable"}
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  data-confirm="Are you sure you want to delete this endpoint?"
                  class="block w-full text-left px-4 py-2 text-sm text-red-600 hover:bg-red-50"
                >
                  Delete
                </button>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Inbound URL card --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-3">Inbound URL</h2>
        <div class="flex items-center gap-2 bg-slate-50 rounded-lg p-3">
          <code class="flex-1 text-sm text-slate-800 font-mono break-all">{@inbound_url}</code>
          <button
            type="button"
            id="copy-inbound-url"
            phx-hook="CopyToClipboard"
            data-clipboard-text={@inbound_url}
            class="shrink-0 text-slate-400 hover:text-emerald-600 p-1.5 rounded transition-colors"
            title="Copy to clipboard"
          >
            <.icon name="hero-clipboard-document" class="w-5 h-5" />
          </button>
        </div>
        <p class="mt-3 text-sm text-slate-500">
          Point your external service (Stripe, GitHub, etc.) to this URL. All incoming requests will be forwarded to <code class="text-slate-700 bg-slate-100 px-1 py-0.5 rounded text-xs">{@endpoint.forward_url}</code>.
        </p>
      </div>

      <%!-- Details --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">Details</h2>
        <dl class="grid grid-cols-2 gap-4">
          <div>
            <dt class="text-sm text-slate-500">Forward URL</dt>
            <dd class="text-sm font-medium text-slate-900 mt-0.5 break-all">
              {@endpoint.forward_url}
            </dd>
          </div>
          <div>
            <dt class="text-sm text-slate-500">Created</dt>
            <dd class="text-sm font-medium text-slate-900 mt-0.5">
              <.local_time id="endpoint-created" datetime={@endpoint.inserted_at} />
            </dd>
          </div>
          <%= if not is_nil(@endpoint.notify_on_failure) do %>
            <div>
              <dt class="text-sm text-slate-500">Failure Alerts</dt>
              <dd class="text-sm font-medium mt-0.5">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(@endpoint.notify_on_failure, do: "bg-emerald-100 text-emerald-700", else: "bg-slate-100 text-slate-600")
                ]}>
                  {if @endpoint.notify_on_failure, do: "On", else: "Off"}
                </span>
              </dd>
            </div>
          <% end %>
          <%= if not is_nil(@endpoint.notify_on_recovery) do %>
            <div>
              <dt class="text-sm text-slate-500">Recovery Alerts</dt>
              <dd class="text-sm font-medium mt-0.5">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(@endpoint.notify_on_recovery, do: "bg-emerald-100 text-emerald-700", else: "bg-slate-100 text-slate-600")
                ]}>
                  {if @endpoint.notify_on_recovery, do: "On", else: "Off"}
                </span>
              </dd>
            </div>
          <% end %>
        </dl>
      </div>

      <%!-- Public Badge --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-3">
          Public Badge
        </h2>
        <div class="flex items-center justify-between">
          <p class="text-sm text-slate-500">
            <%= if @endpoint.badge_token do %>
              Badge is enabled and publicly visible.
            <% else %>
              Enable badges and manage your public status page.
            <% end %>
          </p>
          <.link
            navigate={~p"/status-page"}
            class="text-sm font-medium text-emerald-600 hover:text-emerald-700"
          >
            Manage in Status page
          </.link>
        </div>
      </div>

      <%!-- Recent Events --%>
      <div class="glass-card rounded-2xl p-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">
          Recent Events
        </h2>
        <%= if @events == [] do %>
          <p class="text-sm text-slate-400 text-center py-4">No events received yet</p>
        <% else %>
          <div class="divide-y divide-slate-100">
            <%= for event <- @events do %>
              <div class="py-3 flex items-center gap-3">
                <span class="text-xs font-medium text-slate-500 bg-slate-100 px-2 py-0.5 rounded font-mono shrink-0">
                  {event.method}
                </span>
                <span class="text-sm text-slate-700 flex-1 min-w-0">
                  <.local_time id={"event-#{event.id}"} datetime={event.received_at} />
                  <%= if event.source_ip do %>
                    <span class="text-slate-400 text-xs ml-1">from {event.source_ip}</span>
                  <% end %>
                </span>
                <%= if event.execution do %>
                  <span class={[
                    "text-xs font-medium px-2 py-0.5 rounded shrink-0",
                    execution_status_badge(event.execution.status)
                  ]}>
                    {event.execution.status}
                  </span>
                  <.link
                    navigate={~p"/tasks/#{event.execution.task_id}"}
                    class="text-xs text-slate-500 hover:text-slate-700 hover:bg-slate-100 font-medium shrink-0 px-2 py-1 rounded transition-colors"
                    title="View forwarding task"
                  >
                    View Task
                  </.link>
                <% end %>
                <button
                  type="button"
                  phx-click="replay"
                  phx-value-id={event.id}
                  class="text-xs text-emerald-600 hover:text-emerald-700 hover:bg-emerald-50 font-medium shrink-0 px-2 py-1 rounded transition-colors"
                  title="Replay this event"
                >
                  Replay
                </button>
              </div>
            <% end %>
          </div>

          <%= if length(@events) < @total_events do %>
            <div class="mt-4 text-center">
              <button
                type="button"
                phx-click="load_more"
                class="px-4 py-2 text-sm font-medium text-slate-600 bg-white border border-slate-200 rounded-md hover:bg-white/50 transition-colors"
              >
                Load more
                <span class="text-slate-400">
                  (showing {length(@events)} of {@total_events})
                </span>
              </button>
            </div>
          <% end %>
        <% end %>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ClickOutside">
        export default {
          mounted() {
            this.handler = (e) => {
              if (!this.el.contains(e.target)) {
                this.pushEvent("close_menu", {})
              }
            }
            document.addEventListener("click", this.handler)
          },
          destroyed() {
            document.removeEventListener("click", this.handler)
          }
        }
      </script>

    </Layouts.app>
    """
  end
end
