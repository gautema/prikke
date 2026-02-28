defmodule PrikkeWeb.StatusLive.Index do
  use PrikkeWeb, :live_view

  alias Prikke.StatusPages
  alias Prikke.Tasks
  alias Prikke.Monitors
  alias Prikke.Endpoints
  alias Prikke.Queues
  alias Prikke.Audit

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      {:ok, status_page} = StatusPages.get_or_create_status_page(org)

      base_url = PrikkeWeb.Endpoint.url()

      tasks = Tasks.list_tasks(org, type: "cron")
      monitors = Monitors.list_monitors(org)
      endpoints = Endpoints.list_endpoints(org)
      Queues.ensure_queues_exist(org)
      queues = Queues.list_queues(org)

      items = StatusPages.list_items(status_page)
      visible_set = build_visible_set(items)
      items_by_resource = build_items_map(items)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Status Page")
       |> assign(:status_page, status_page)
       |> assign(:form, to_form(StatusPages.change_status_page(status_page)))
       |> assign(:tasks, tasks)
       |> assign(:monitors, monitors)
       |> assign(:endpoints, endpoints)
       |> assign(:queues, queues)
       |> assign(:visible_set, visible_set)
       |> assign(:items_by_resource, items_by_resource)
       |> assign(:base_url, base_url)}
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
    status_page = socket.assigns.status_page

    resource_name = get_resource_name(type, org, id)
    {:ok, _item} = StatusPages.add_item(status_page, type, id)

    Audit.log(scope, :enabled, :status_page_badge, id,
      organization_id: org.id,
      metadata: %{"resource_type" => type, "resource_name" => resource_name}
    )

    {:noreply, reload_items(socket)}
  end

  def handle_event("disable_badge", %{"type" => type, "id" => id}, socket) do
    org = socket.assigns.organization
    scope = socket.assigns.current_scope
    status_page = socket.assigns.status_page

    resource_name = get_resource_name(type, org, id)
    {:ok, _item} = StatusPages.remove_item(status_page, type, id)

    Audit.log(scope, :disabled, :status_page_badge, id,
      organization_id: org.id,
      metadata: %{"resource_type" => type, "resource_name" => resource_name}
    )

    {:noreply, reload_items(socket)}
  end

  defp get_resource_name("task", org, id), do: Tasks.get_task!(org, id).name
  defp get_resource_name("monitor", org, id), do: Monitors.get_monitor!(org, id).name
  defp get_resource_name("endpoint", org, id), do: Endpoints.get_endpoint!(org, id).name
  defp get_resource_name("queue", org, id), do: Queues.get_queue!(org, id).name

  defp reload_items(socket) do
    items = StatusPages.list_items(socket.assigns.status_page)

    socket
    |> assign(:visible_set, build_visible_set(items))
    |> assign(:items_by_resource, build_items_map(items))
  end

  defp build_visible_set(items) do
    MapSet.new(items, fn item -> {item.resource_type, item.resource_id} end)
  end

  defp build_items_map(items) do
    Map.new(items, fn item -> {{item.resource_type, item.resource_id}, item} end)
  end

  defp visible?(visible_set, type, id) do
    MapSet.member?(visible_set, {type, id})
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
                    {@base_url}/s/{Phoenix.HTML.Form.input_value(@form, :slug) || @status_page.slug}
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
                    <.visibility_toggle type="task" id={task.id} visible={visible?(@visible_set, "task", task.id)} />
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
                    <.visibility_toggle type="monitor" id={monitor.id} visible={visible?(@visible_set, "monitor", monitor.id)} />
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Endpoints --%>
          <%= if @endpoints != [] do %>
            <div class="mb-6">
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
                    <.visibility_toggle type="endpoint" id={endpoint.id} visible={visible?(@visible_set, "endpoint", endpoint.id)} />
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Queues --%>
          <%= if @queues != [] do %>
            <div class="mb-6">
              <h3 class="text-xs font-medium text-slate-400 uppercase tracking-wider mb-2">
                Queues
              </h3>
              <div class="divide-y divide-slate-100">
                <%= for queue <- @queues do %>
                  <div class="py-3 flex items-center justify-between">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class={[
                        "w-2 h-2 rounded-full shrink-0",
                        if(queue.paused, do: "bg-slate-300", else: "bg-emerald-500")
                      ]} />
                      <span class="text-sm font-medium text-slate-900 truncate">{queue.name}</span>
                    </div>
                    <.visibility_toggle type="queue" id={queue.id} visible={visible?(@visible_set, "queue", queue.id)} />
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @tasks == [] && @monitors == [] && @endpoints == [] && @queues == [] do %>
            <p class="text-sm text-slate-400 text-center py-4">
              No resources yet. Create tasks, monitors, or endpoints to manage their visibility.
            </p>
          <% end %>
        </div>

        <%!-- Embed Codes Card --%>
        <% visible_items = Map.values(@items_by_resource) %>
        <%= if visible_items != [] do %>
          <div class="glass-card rounded-2xl p-6">
            <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">
              Badge Embed Codes
            </h2>
            <p class="text-sm text-slate-500 mb-4">
              Copy these snippets to embed status badges in your README or documentation.
            </p>
            <div class="space-y-5">
              <%= for task <- @tasks, item = @items_by_resource[{"task", task.id}], item != nil do %>
                <.badge_embed_section
                  name={task.name}
                  type="Task"
                  badge_type="task"
                  badge_token={item.badge_token}
                  resource_id={task.id}
                  base_url={@base_url}
                />
              <% end %>
              <%= for monitor <- @monitors, item = @items_by_resource[{"monitor", monitor.id}], item != nil do %>
                <.badge_embed_section
                  name={monitor.name}
                  type="Monitor"
                  badge_type="monitor"
                  badge_token={item.badge_token}
                  resource_id={monitor.id}
                  base_url={@base_url}
                />
              <% end %>
              <%= for endpoint <- @endpoints, item = @items_by_resource[{"endpoint", endpoint.id}], item != nil do %>
                <.badge_embed_section
                  name={endpoint.name}
                  type="Endpoint"
                  badge_type="endpoint"
                  badge_token={item.badge_token}
                  resource_id={endpoint.id}
                  base_url={@base_url}
                />
              <% end %>
              <%= for queue <- @queues, item = @items_by_resource[{"queue", queue.id}], item != nil do %>
                <.badge_embed_section
                  name={queue.name}
                  type="Queue"
                  badge_type="queue"
                  badge_token={item.badge_token}
                  resource_id={queue.id}
                  base_url={@base_url}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp visibility_toggle(assigns) do
    ~H"""
    <%= if @visible do %>
      <button
        type="button"
        phx-click="disable_badge"
        phx-value-type={@type}
        phx-value-id={@id}
        class="text-xs font-medium text-emerald-700 bg-emerald-50 hover:bg-emerald-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
      >
        Visible
      </button>
    <% else %>
      <button
        type="button"
        phx-click="enable_badge"
        phx-value-type={@type}
        phx-value-id={@id}
        class="text-xs font-medium text-slate-500 bg-slate-50 hover:bg-slate-100 px-3 py-1 rounded-md transition-colors cursor-pointer"
      >
        Hidden
      </button>
    <% end %>
    """
  end

  defp badge_embed_section(assigns) do
    ~H"""
    <div>
      <p class="text-xs font-medium text-slate-600 mb-2">{@name} ({@type})</p>
      <div class="space-y-2">
        <div>
          <p class="text-xs text-slate-400 mb-1">Status</p>
          <div class="flex items-center gap-2 bg-slate-100 rounded p-2">
            <code class="flex-1 text-xs text-slate-700 break-all select-all">
              ![{@name}]({@base_url}/badge/{@badge_type}/{@badge_token}/status.svg)
            </code>
            <button
              type="button"
              id={"copy-#{@badge_type}-status-#{@resource_id}"}
              phx-hook="CopyToClipboard"
              data-clipboard-text={"![#{@name}](#{@base_url}/badge/#{@badge_type}/#{@badge_token}/status.svg)"}
              class="shrink-0 text-slate-400 hover:text-emerald-600 p-1 rounded transition-colors cursor-pointer"
              title="Copy to clipboard"
            >
              <.icon name="hero-clipboard-document" class="w-4 h-4" />
            </button>
          </div>
        </div>
        <div>
          <p class="text-xs text-slate-400 mb-1">Uptime</p>
          <div class="flex items-center gap-2 bg-slate-100 rounded p-2">
            <code class="flex-1 text-xs text-slate-700 break-all select-all">
              ![{@name} uptime]({@base_url}/badge/{@badge_type}/{@badge_token}/uptime.svg)
            </code>
            <button
              type="button"
              id={"copy-#{@badge_type}-uptime-#{@resource_id}"}
              phx-hook="CopyToClipboard"
              data-clipboard-text={"![#{@name} uptime](#{@base_url}/badge/#{@badge_type}/#{@badge_token}/uptime.svg)"}
              class="shrink-0 text-slate-400 hover:text-emerald-600 p-1 rounded transition-colors cursor-pointer"
              title="Copy to clipboard"
            >
              <.icon name="hero-clipboard-document" class="w-4 h-4" />
            </button>
          </div>
        </div>
      </div>
    </div>
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
