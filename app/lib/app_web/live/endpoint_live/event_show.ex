defmodule PrikkeWeb.EndpointLive.EventShow do
  use PrikkeWeb, :live_view

  alias Prikke.Endpoints

  @impl true
  def mount(%{"endpoint_id" => endpoint_id, "event_id" => event_id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      endpoint = Endpoints.get_endpoint(org, endpoint_id)

      cond do
        is_nil(endpoint) ->
          {:ok,
           socket
           |> put_flash(:error, "Endpoint not found")
           |> redirect(to: ~p"/endpoints")}

        true ->
          try do
            event = Endpoints.get_inbound_event!(endpoint, event_id)

            if connected?(socket) do
              Endpoints.subscribe_endpoints(org)
            end

            {:ok,
             socket
             |> assign(:organization, org)
             |> assign(:endpoint, endpoint)
             |> assign(:event, event)
             |> assign(:page_title, "Event Details")}
          rescue
            Ecto.NoResultsError ->
              {:ok,
               socket
               |> put_flash(:error, "Event not found")
               |> redirect(to: ~p"/endpoints/#{endpoint_id}")}
          end
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_event("replay", _params, socket) do
    endpoint = socket.assigns.endpoint
    event = socket.assigns.event

    case Endpoints.replay_event(endpoint, event) do
      {:ok, _executions} ->
        # Re-fetch event to get updated tasks
        event = Endpoints.get_inbound_event!(endpoint, event.id)

        {:noreply,
         socket
         |> assign(:event, event)
         |> put_flash(:info, "Event replayed")}

      {:error, :no_tasks} ->
        {:noreply, put_flash(socket, :error, "Cannot replay: no linked tasks")}

      {:error, :task_deleted} ->
        {:noreply, put_flash(socket, :error, "Cannot replay: linked tasks have been deleted")}
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

  defp format_body(nil), do: nil
  defp format_body(""), do: nil

  defp format_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      {:error, _} -> body
    end
  end

  defp json?(nil), do: false
  defp json?(""), do: false

  defp json?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp execution_status_badge("success"), do: "bg-emerald-100 text-emerald-700"
  defp execution_status_badge("failed"), do: "bg-red-100 text-red-700"
  defp execution_status_badge("timeout"), do: "bg-amber-100 text-amber-700"
  defp execution_status_badge("running"), do: "bg-blue-100 text-blue-700"
  defp execution_status_badge("pending"), do: "bg-slate-100 text-slate-600"
  defp execution_status_badge(_), do: "bg-slate-100 text-slate-600"

  defp status_code_color(code) when code >= 200 and code < 300, do: "text-emerald-600"
  defp status_code_color(code) when code >= 300 and code < 400, do: "text-blue-600"
  defp status_code_color(code) when code >= 400 and code < 500, do: "text-amber-600"
  defp status_code_color(_), do: "text-red-600"

  defp format_duration(nil), do: "\u2014"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 2)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 2)}m"

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

      <%!-- Header --%>
      <div class="flex flex-col sm:flex-row sm:justify-between sm:items-start gap-4 mb-6">
        <div>
          <div class="flex items-center gap-3 flex-wrap">
            <h1 class="text-xl sm:text-2xl font-bold text-slate-900">Event Details</h1>
            <span class="text-xs font-medium text-slate-500 bg-slate-100 px-2 py-0.5 rounded font-mono">
              {@event.method}
            </span>
          </div>
          <p class="text-sm text-slate-500 mt-1">
            Received <.local_time id="event-received" datetime={@event.received_at} format="full" />
          </p>
        </div>
        <button
          type="button"
          phx-click="replay"
          class="px-4 py-2 bg-emerald-600 text-white text-sm font-medium rounded-md hover:bg-emerald-700 transition-colors flex items-center gap-2"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Replay
        </button>
      </div>

      <%!-- Request Details --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">
          Request
        </h2>
        <div class="space-y-4">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div>
              <span class="text-xs text-slate-500 uppercase">Method</span>
              <p class="text-sm font-medium text-slate-900 font-mono mt-0.5">{@event.method}</p>
            </div>
            <%= if @event.source_ip do %>
              <div>
                <span class="text-xs text-slate-500 uppercase">Source IP</span>
                <p class="text-sm font-medium text-slate-900 font-mono mt-0.5">{@event.source_ip}</p>
              </div>
            <% end %>
          </div>

          <%= if @event.headers && @event.headers != %{} do %>
            <div>
              <span class="text-xs text-slate-500 uppercase">Headers</span>
              <div class="bg-slate-50 rounded-lg p-3 mt-1 overflow-x-auto">
                <dl class="space-y-1">
                  <%= for {key, value} <- Enum.sort(@event.headers) do %>
                    <div class="flex gap-2 text-xs font-mono">
                      <dt class="text-slate-500 shrink-0">{key}:</dt>
                      <dd class="text-slate-800 break-all">{value}</dd>
                    </div>
                  <% end %>
                </dl>
              </div>
            </div>
          <% end %>

          <%= if @event.body && @event.body != "" do %>
            <div>
              <span class="text-xs text-slate-500 uppercase">
                Body
                <%= if json?(@event.body) do %>
                  <span class="text-slate-400 normal-case ml-1">(JSON)</span>
                <% end %>
              </span>
              <pre
                class="text-xs bg-slate-50 p-3 rounded-lg mt-1 overflow-x-auto whitespace-pre-wrap max-h-96 overflow-y-auto font-mono"
                phx-no-curly-interpolation
              ><%= format_body(@event.body) %></pre>
            </div>
          <% else %>
            <div>
              <span class="text-xs text-slate-500 uppercase">Body</span>
              <p class="text-slate-400 text-sm mt-1 italic">No request body</p>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Forwarding Details --%>
      <div class="glass-card rounded-2xl p-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">
          <%= cond do %>
            <% length(Map.get(@event, :tasks, [])) > 1 -> %>
              Forwarding ({length(@event.tasks)} destinations)
            <% true -> %>
              Forwarding
          <% end %>
        </h2>
        <%= cond do %>
          <% Map.get(@event, :tasks, []) == [] -> %>
            <p class="text-sm text-slate-400 italic">No forwarding data available</p>
          <% true -> %>
            <div class="space-y-4">
              <%= for task <- @event.tasks do %>
                <div class="border border-slate-100 rounded-lg p-4">
                  <div class="text-xs text-slate-500 font-mono mb-3 break-all">{task.url}</div>
                  <%= if Map.get(task, :latest_execution) do %>
                    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-3">
                      <div>
                        <span class="text-xs text-slate-500 uppercase">Status</span>
                        <div class="mt-1">
                          <span class={[
                            "text-xs font-medium px-2 py-0.5 rounded",
                            execution_status_badge(task.latest_execution.status)
                          ]}>
                            {task.latest_execution.status}
                          </span>
                        </div>
                      </div>
                      <%= if task.latest_execution.status_code do %>
                        <div>
                          <span class="text-xs text-slate-500 uppercase">Status Code</span>
                          <p class={[
                            "text-lg font-mono font-bold mt-0.5",
                            status_code_color(task.latest_execution.status_code)
                          ]}>
                            {task.latest_execution.status_code}
                          </p>
                        </div>
                      <% end %>
                      <div>
                        <span class="text-xs text-slate-500 uppercase">Duration</span>
                        <p class="text-sm font-medium text-slate-900 mt-0.5">
                          {format_duration(task.latest_execution.duration_ms)}
                        </p>
                      </div>
                    </div>
                    <div class="flex items-center gap-3">
                      <.link
                        navigate={~p"/tasks/#{task.id}"}
                        class="text-sm text-emerald-600 hover:text-emerald-700 font-medium flex items-center gap-1"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View Task
                      </.link>
                      <.link
                        navigate={~p"/tasks/#{task.id}/executions/#{task.latest_execution.id}"}
                        class="text-sm text-emerald-600 hover:text-emerald-700 font-medium flex items-center gap-1"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View Execution
                      </.link>
                    </div>
                  <% else %>
                    <p class="text-sm text-slate-400 italic">Execution pending</p>
                  <% end %>
                </div>
              <% end %>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
