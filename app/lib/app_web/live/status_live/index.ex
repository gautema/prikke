defmodule PrikkeWeb.StatusLive.Index do
  use PrikkeWeb, :live_view

  alias Prikke.StatusPages
  alias Prikke.Tasks
  alias Prikke.Monitors
  alias Prikke.Endpoints
  alias Prikke.Audit

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      {:ok, status_page} = StatusPages.get_or_create_status_page(org)

      host = PrikkeWeb.Endpoint.host()

      tasks = Tasks.list_tasks(org, type: "cron")
      monitors = Monitors.list_monitors(org)
      endpoints = Endpoints.list_endpoints(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Status Page")
       |> assign(:status_page, status_page)
       |> assign(:form, to_form(StatusPages.change_status_page(status_page)))
       |> assign(:tasks, tasks)
       |> assign(:monitors, monitors)
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
  def handle_event("validate", %{"status_page" => params}, socket) do
    changeset =
      StatusPages.change_status_page(socket.assigns.status_page, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"status_page" => params}, socket) do
    old = socket.assigns.status_page

    case StatusPages.update_status_page(old, params) do
      {:ok, status_page} ->
        changes =
          Audit.compute_changes(old, status_page, [:title, :slug, :description, :enabled])

        if changes != %{} do
          Audit.log(socket.assigns.current_scope, :updated, :status_page, status_page.id,
            organization_id: socket.assigns.organization.id,
            changes: changes
          )
        end

        {:noreply,
         socket
         |> assign(:status_page, status_page)
         |> assign(:form, to_form(StatusPages.change_status_page(status_page)))
         |> put_flash(:info, "Status page updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("enable_badge", %{"type" => type, "id" => id}, socket) do
    org = socket.assigns.organization
    scope = socket.assigns.current_scope

    case type do
      "task" ->
        task = Tasks.get_task!(org, id)
        {:ok, _} = Tasks.enable_badge(org, task)
        Audit.log(scope, :enabled, :status_page_badge, id,
          organization_id: org.id,
          metadata: %{"resource_type" => "task", "resource_name" => task.name}
        )
        {:noreply, assign(socket, :tasks, Tasks.list_tasks(org, type: "cron"))}

      "monitor" ->
        monitor = Monitors.get_monitor!(org, id)
        {:ok, _} = Monitors.enable_badge(org, monitor)
        Audit.log(scope, :enabled, :status_page_badge, id,
          organization_id: org.id,
          metadata: %{"resource_type" => "monitor", "resource_name" => monitor.name}
        )
        {:noreply, assign(socket, :monitors, Monitors.list_monitors(org))}

      "endpoint" ->
        endpoint = Endpoints.get_endpoint!(org, id)
        {:ok, _} = Endpoints.enable_badge(org, endpoint)
        Audit.log(scope, :enabled, :status_page_badge, id,
          organization_id: org.id,
          metadata: %{"resource_type" => "endpoint", "resource_name" => endpoint.name}
        )
        {:noreply, assign(socket, :endpoints, Endpoints.list_endpoints(org))}
    end
  end

  def handle_event("disable_badge", %{"type" => type, "id" => id}, socket) do
    org = socket.assigns.organization
    scope = socket.assigns.current_scope

    case type do
      "task" ->
        task = Tasks.get_task!(org, id)
        {:ok, _} = Tasks.disable_badge(org, task)
        Audit.log(scope, :disabled, :status_page_badge, id,
          organization_id: org.id,
          metadata: %{"resource_type" => "task", "resource_name" => task.name}
        )
        {:noreply, assign(socket, :tasks, Tasks.list_tasks(org, type: "cron"))}

      "monitor" ->
        monitor = Monitors.get_monitor!(org, id)
        {:ok, _} = Monitors.disable_badge(org, monitor)
        Audit.log(scope, :disabled, :status_page_badge, id,
          organization_id: org.id,
          metadata: %{"resource_type" => "monitor", "resource_name" => monitor.name}
        )
        {:noreply, assign(socket, :monitors, Monitors.list_monitors(org))}

      "endpoint" ->
        endpoint = Endpoints.get_endpoint!(org, id)
        {:ok, _} = Endpoints.disable_badge(org, endpoint)
        Audit.log(scope, :disabled, :status_page_badge, id,
          organization_id: org.id,
          metadata: %{"resource_type" => "endpoint", "resource_name" => endpoint.name}
        )
        {:noreply, assign(socket, :endpoints, Endpoints.list_endpoints(org))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-bold text-slate-900">Status Page</h1>
          <p class="text-sm text-slate-500 mt-1">
            Configure your public status page and manage which resources are visible.
          </p>
        </div>

        <%!-- Settings Card --%>
        <div class="glass-card rounded-2xl p-6">
          <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">
            Settings
          </h2>
          <.form for={@form} id="status-page-form" phx-change="validate" phx-submit="save">
            <div class="space-y-4">
              <.input field={@form[:title]} type="text" label="Page Title" />
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description"
                placeholder="Optional description shown below the title"
              />
              <div>
                <.input field={@form[:slug]} type="text" label="URL Slug" />
                <p class="text-xs text-slate-400 mt-1">
                  Your status page will be available at
                  <span class="font-mono text-slate-600">
                    https://{@host}/s/{Phoenix.HTML.Form.input_value(@form, :slug) || @status_page.slug}
                  </span>
                </p>
              </div>
              <div class="flex items-center gap-3">
                <.input field={@form[:enabled]} type="checkbox" label="Enable public status page" />
              </div>
              <div class="flex items-center gap-3">
                <button
                  type="submit"
                  class="px-4 py-2 text-sm font-medium text-white bg-emerald-600 hover:bg-emerald-700 rounded-lg transition-colors cursor-pointer"
                >
                  Save Settings
                </button>
                <%= if @status_page.enabled do %>
                  <.link
                    href={~p"/s/#{@status_page.slug}"}
                    target="_blank"
                    class="text-sm text-emerald-600 hover:text-emerald-700"
                  >
                    View public page
                  </.link>
                <% end %>
              </div>
            </div>
          </.form>
        </div>

        <%!-- Resources Card --%>
        <div class="glass-card rounded-2xl p-6">
          <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">
            Resources
          </h2>
          <p class="text-sm text-slate-500 mb-4">
            Toggle which resources appear on your public status page. Enabling a resource also creates a public badge you can embed.
          </p>

          <%!-- Tasks --%>
          <%= if @tasks != [] do %>
            <div class="mb-6">
              <h3 class="text-xs font-medium text-slate-400 uppercase tracking-wider mb-2">
                Cron Tasks
              </h3>
              <div class="divide-y divide-slate-100">
                <%= for task <- @tasks do %>
                  <div class="py-3 flex items-center justify-between">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class={[
                        "w-2 h-2 rounded-full shrink-0",
                        status_dot_color(task_status_label(task))
                      ]} />
                      <span class="text-sm font-medium text-slate-900 truncate">{task.name}</span>
                    </div>
                    <%= if task.badge_token do %>
                      <button
                        type="button"
                        phx-click="disable_badge"
                        phx-value-type="task"
                        phx-value-id={task.id}
                        class="text-xs font-medium text-emerald-700 bg-emerald-50 hover:bg-emerald-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
                      >
                        Visible
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="enable_badge"
                        phx-value-type="task"
                        phx-value-id={task.id}
                        class="text-xs font-medium text-slate-500 bg-slate-50 hover:bg-slate-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
                      >
                        Hidden
                      </button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Monitors --%>
          <%= if @monitors != [] do %>
            <div class="mb-6">
              <h3 class="text-xs font-medium text-slate-400 uppercase tracking-wider mb-2">
                Monitors
              </h3>
              <div class="divide-y divide-slate-100">
                <%= for monitor <- @monitors do %>
                  <div class="py-3 flex items-center justify-between">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class={[
                        "w-2 h-2 rounded-full shrink-0",
                        status_dot_color(monitor.status)
                      ]} />
                      <span class="text-sm font-medium text-slate-900 truncate">{monitor.name}</span>
                    </div>
                    <%= if monitor.badge_token do %>
                      <button
                        type="button"
                        phx-click="disable_badge"
                        phx-value-type="monitor"
                        phx-value-id={monitor.id}
                        class="text-xs font-medium text-emerald-700 bg-emerald-50 hover:bg-emerald-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
                      >
                        Visible
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="enable_badge"
                        phx-value-type="monitor"
                        phx-value-id={monitor.id}
                        class="text-xs font-medium text-slate-500 bg-slate-50 hover:bg-slate-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
                      >
                        Hidden
                      </button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Endpoints --%>
          <%= if @endpoints != [] do %>
            <div>
              <h3 class="text-xs font-medium text-slate-400 uppercase tracking-wider mb-2">
                Endpoints
              </h3>
              <div class="divide-y divide-slate-100">
                <%= for endpoint <- @endpoints do %>
                  <div class="py-3 flex items-center justify-between">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class={[
                        "w-2 h-2 rounded-full shrink-0",
                        if(endpoint.enabled, do: "bg-emerald-500", else: "bg-slate-300")
                      ]} />
                      <span class="text-sm font-medium text-slate-900 truncate">{endpoint.name}</span>
                    </div>
                    <%= if endpoint.badge_token do %>
                      <button
                        type="button"
                        phx-click="disable_badge"
                        phx-value-type="endpoint"
                        phx-value-id={endpoint.id}
                        class="text-xs font-medium text-emerald-700 bg-emerald-50 hover:bg-emerald-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
                      >
                        Visible
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="enable_badge"
                        phx-value-type="endpoint"
                        phx-value-id={endpoint.id}
                        class="text-xs font-medium text-slate-500 bg-slate-50 hover:bg-slate-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
                      >
                        Hidden
                      </button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @tasks == [] && @monitors == [] && @endpoints == [] do %>
            <p class="text-sm text-slate-400 text-center py-4">
              No resources yet. Create tasks, monitors, or endpoints to manage their visibility.
            </p>
          <% end %>
        </div>

        <%!-- Embed Codes Card --%>
        <% visible_tasks = Enum.filter(@tasks, & &1.badge_token)
           visible_monitors = Enum.filter(@monitors, & &1.badge_token)
           visible_endpoints = Enum.filter(@endpoints, & &1.badge_token) %>
        <%= if visible_tasks != [] || visible_monitors != [] || visible_endpoints != [] do %>
          <div class="glass-card rounded-2xl p-6">
            <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">
              Badge Embed Codes
            </h2>
            <p class="text-sm text-slate-500 mb-4">
              Copy these snippets to embed status badges in your README or documentation.
            </p>
            <div class="space-y-5">
              <%= for task <- visible_tasks do %>
                <div>
                  <p class="text-xs font-medium text-slate-600 mb-2">{task.name} (Task)</p>
                  <div class="space-y-2">
                    <div>
                      <p class="text-xs text-slate-400 mb-1">Status</p>
                      <div class="bg-slate-100 rounded p-2">
                        <code class="text-xs text-slate-700 break-all select-all">![{task.name}](https://{@host}/badge/task/{task.badge_token}/status.svg)</code>
                      </div>
                    </div>
                    <div>
                      <p class="text-xs text-slate-400 mb-1">Uptime</p>
                      <div class="bg-slate-100 rounded p-2">
                        <code class="text-xs text-slate-700 break-all select-all">![{task.name} uptime](https://{@host}/badge/task/{task.badge_token}/uptime.svg)</code>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
              <%= for monitor <- visible_monitors do %>
                <div>
                  <p class="text-xs font-medium text-slate-600 mb-2">{monitor.name} (Monitor)</p>
                  <div class="space-y-2">
                    <div>
                      <p class="text-xs text-slate-400 mb-1">Status</p>
                      <div class="bg-slate-100 rounded p-2">
                        <code class="text-xs text-slate-700 break-all select-all">![{monitor.name}](https://{@host}/badge/monitor/{monitor.badge_token}/status.svg)</code>
                      </div>
                    </div>
                    <div>
                      <p class="text-xs text-slate-400 mb-1">Uptime</p>
                      <div class="bg-slate-100 rounded p-2">
                        <code class="text-xs text-slate-700 break-all select-all">![{monitor.name} uptime](https://{@host}/badge/monitor/{monitor.badge_token}/uptime.svg)</code>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
              <%= for endpoint <- visible_endpoints do %>
                <div>
                  <p class="text-xs font-medium text-slate-600 mb-2">{endpoint.name} (Endpoint)</p>
                  <div class="space-y-2">
                    <div>
                      <p class="text-xs text-slate-400 mb-1">Status</p>
                      <div class="bg-slate-100 rounded p-2">
                        <code class="text-xs text-slate-700 break-all select-all">![{endpoint.name}](https://{@host}/badge/endpoint/{endpoint.badge_token}/status.svg)</code>
                      </div>
                    </div>
                    <div>
                      <p class="text-xs text-slate-400 mb-1">Uptime</p>
                      <div class="bg-slate-100 rounded p-2">
                        <code class="text-xs text-slate-700 break-all select-all">![{endpoint.name} uptime](https://{@host}/badge/endpoint/{endpoint.badge_token}/uptime.svg)</code>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
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

  defp task_status_label(%{enabled: false}), do: "paused"
  defp task_status_label(%{last_execution_status: s}) when is_binary(s), do: s
  defp task_status_label(_), do: "unknown"

  defp status_dot_color("success"), do: "bg-emerald-500"
  defp status_dot_color("passing"), do: "bg-emerald-500"
  defp status_dot_color("up"), do: "bg-emerald-500"
  defp status_dot_color("failed"), do: "bg-red-500"
  defp status_dot_color("failing"), do: "bg-red-500"
  defp status_dot_color("down"), do: "bg-red-500"
  defp status_dot_color("timeout"), do: "bg-orange-500"
  defp status_dot_color("degraded"), do: "bg-orange-500"
  defp status_dot_color(_), do: "bg-slate-300"
end
