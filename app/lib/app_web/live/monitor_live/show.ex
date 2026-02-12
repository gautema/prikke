defmodule PrikkeWeb.MonitorLive.Show do
  use PrikkeWeb, :live_view

  alias Prikke.Monitors

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      monitor = Monitors.get_monitor(org, id)

      if is_nil(monitor) do
        {:ok,
         socket
         |> put_flash(:error, "Monitor not found")
         |> redirect(to: ~p"/monitors")}
      else
        if connected?(socket) do
          Monitors.subscribe_monitors(org)
        end

        timeline = Monitors.build_event_timeline(monitor, limit: 30)
        host = Application.get_env(:app, PrikkeWeb.Endpoint)[:url][:host] || "runlater.eu"
        ping_url = "https://#{host}/ping/#{monitor.ping_token}"
        status_days = if org.tier == "pro", do: 30, else: 7
        daily_status = Monitors.get_daily_status([monitor], status_days)

        {:ok,
         socket
         |> assign(:organization, org)
         |> assign(:monitor, monitor)
         |> assign(:timeline, timeline)
         |> assign(:ping_url, ping_url)
         |> assign(:page_title, monitor.name)
         |> assign(:menu_open, false)
         |> assign(:status_days, status_days)
         |> assign(:daily_status, daily_status)
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
  def handle_info({:monitor_updated, monitor}, socket) do
    if monitor.id == socket.assigns.monitor.id do
      timeline = Monitors.build_event_timeline(monitor, limit: 30)
      daily_status = Monitors.get_daily_status([monitor], socket.assigns.status_days)

      {:noreply,
       socket
       |> assign(:monitor, monitor)
       |> assign(:timeline, timeline)
       |> assign(:daily_status, daily_status)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:monitor_deleted, monitor}, socket) do
    if monitor.id == socket.assigns.monitor.id do
      {:noreply,
       socket
       |> put_flash(:info, "Monitor was deleted")
       |> push_navigate(to: ~p"/monitors")}
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
    monitor = socket.assigns.monitor
    {:ok, updated} = Monitors.toggle_monitor(org, monitor)
    {:noreply, assign(socket, :monitor, updated)}
  end

  def handle_event("toggle_mute", _, socket) do
    org = socket.assigns.organization
    monitor = socket.assigns.monitor

    case Monitors.update_monitor(org, monitor, %{muted: !monitor.muted}) do
      {:ok, updated} ->
        {:noreply, assign(socket, :monitor, updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update mute setting")}
    end
  end

  def handle_event("enable_badge", _, socket) do
    org = socket.assigns.organization
    monitor = socket.assigns.monitor

    case Monitors.enable_badge(org, monitor) do
      {:ok, updated} ->
        {:noreply, assign(socket, :monitor, updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to enable badge")}
    end
  end

  def handle_event("disable_badge", _, socket) do
    org = socket.assigns.organization
    monitor = socket.assigns.monitor

    case Monitors.disable_badge(org, monitor) do
      {:ok, updated} ->
        {:noreply, assign(socket, :monitor, updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to disable badge")}
    end
  end

  def handle_event("delete", _, socket) do
    org = socket.assigns.organization
    monitor = socket.assigns.monitor
    {:ok, _} = Monitors.delete_monitor(org, monitor)

    {:noreply,
     socket
     |> put_flash(:info, "Monitor deleted")
     |> push_navigate(to: ~p"/monitors")}
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

  defp uptime_line(%{days: []} = assigns) do
    ~H"""
    <div class="flex items-center">
      <span class="text-xs text-slate-300">No data yet</span>
    </div>
    """
  end

  defp uptime_line(assigns) do
    up_days = Enum.count(assigns.days, fn {_, %{status: s}} -> s == "up" end)
    total_active = Enum.count(assigns.days, fn {_, %{status: s}} -> s != "none" end)
    uptime_pct = if total_active > 0, do: round(up_days / total_active * 100), else: 0
    assigns = assign(assigns, :uptime_pct, uptime_pct)

    ~H"""
    <div class="flex items-center gap-0.5">
      <div class="flex items-center gap-px flex-1">
        <%= for {{date, %{status: status, actual: actual, expected: expected}}, idx} <- Enum.with_index(@days) do %>
          <div class="flex-1 group relative">
            <div class={["h-7 first:rounded-l-sm last:rounded-r-sm", day_status_color(status)]} />
            <div class={[
              "hidden group-hover:block absolute bottom-full mb-2 px-2 py-1 bg-slate-800 text-white text-xs rounded whitespace-nowrap z-10",
              if(idx < 3,
                do: "left-0",
                else: if(idx > length(@days) - 4, do: "right-0", else: "left-1/2 -translate-x-1/2")
              )
            ]}>
              <div class="font-medium">{Calendar.strftime(date, "%b %d")}</div>
              <div>{day_status_label(status)}</div>
              <%= if status in ["degraded", "down"] and expected > 0 do %>
                <div class="text-slate-300">{actual} / {expected} pings</div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
      <span class="text-xs text-slate-400 ml-3 shrink-0 tabular-nums">
        {@uptime_pct}% · {@label}
      </span>
    </div>
    """
  end

  defp day_status_color("up"), do: "bg-emerald-500"
  defp day_status_color("degraded"), do: "bg-amber-400"
  defp day_status_color("down"), do: "bg-red-500"
  defp day_status_color("none"), do: "bg-slate-100"
  defp day_status_color(_), do: "bg-slate-100"

  defp day_status_label("up"), do: "Operational"
  defp day_status_label("degraded"), do: "Degraded"
  defp day_status_label("down"), do: "Down"
  defp day_status_label("none"), do: "No data"
  defp day_status_label(_), do: "Unknown"

  defp status_color("up"), do: "bg-emerald-100 text-emerald-700"
  defp status_color("down"), do: "bg-red-100 text-red-700"
  defp status_color("new"), do: "bg-slate-100 text-slate-600"
  defp status_color("paused"), do: "bg-amber-100 text-amber-700"
  defp status_color(_), do: "bg-slate-100 text-slate-600"

  defp status_label("up"), do: "Up"
  defp status_label("down"), do: "Down"
  defp status_label("new"), do: "Awaiting first ping"
  defp status_label("paused"), do: "Paused"
  defp status_label(_), do: "Unknown"

  defp format_schedule(%{schedule_type: "cron", cron_expression: expr}), do: "Cron: #{expr}"

  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}) when s < 120,
    do: "Every #{s} seconds"

  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}) when s < 7200,
    do: "Every #{div(s, 60)} minutes"

  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}) when s < 172_800,
    do: "Every #{div(s, 3600)} hours"

  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}),
    do: "Every #{div(s, 86400)} days"

  defp format_schedule(_), do: "Unknown"

  defp format_period_duration(from, to) do
    minutes = div(DateTime.diff(to, from, :second), 60)
    format_gap_duration(max(minutes, 1))
  end

  defp format_gap_duration(minutes) when minutes < 60, do: "#{minutes} min"

  defp format_gap_duration(minutes) when minutes < 1440 do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    if mins > 0, do: "#{hours}h #{mins}m", else: "#{hours}h"
  end

  defp format_gap_duration(minutes) do
    days = div(minutes, 1440)
    hours = div(rem(minutes, 1440), 60)
    if hours > 0, do: "#{days}d #{hours}h", else: "#{days}d"
  end

  defp format_grace(%{grace_period_seconds: 0}), do: "None"
  defp format_grace(%{grace_period_seconds: s}) when s < 120, do: "#{s} seconds"
  defp format_grace(%{grace_period_seconds: s}) when s < 7200, do: "#{div(s, 60)} minutes"
  defp format_grace(%{grace_period_seconds: s}), do: "#{div(s, 3600)} hours"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mb-4">
        <.link
          navigate={~p"/monitors"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Monitors
        </.link>
      </div>

      <div class="flex justify-between items-center mb-6">
        <div class="flex items-center gap-3">
          <h1 class="text-xl sm:text-2xl font-bold text-slate-900">{@monitor.name}</h1>
          <%= if @monitor.muted do %>
            <span
              class="inline-flex items-center gap-1 text-xs font-medium px-2 py-0.5 rounded bg-slate-100 text-slate-500"
              title="Notifications muted"
            >
              <.icon name="hero-bell-slash" class="w-3.5 h-3.5" /> Muted
            </span>
          <% end %>
          <span class={["text-xs font-medium px-2 py-0.5 rounded", status_color(@monitor.status)]}>
            {status_label(@monitor.status)}
          </span>
        </div>

        <div class="flex items-center gap-2">
          <div id="monitor-actions-menu" class="relative" phx-hook=".ClickOutside">
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
                  navigate={~p"/monitors/#{@monitor.id}/edit"}
                  class="block w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50"
                >
                  Edit
                </.link>
                <button
                  type="button"
                  phx-click="toggle_mute"
                  class="w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50 flex items-center gap-2"
                >
                  <%= if @monitor.muted do %>
                    <.icon name="hero-bell" class="w-4 h-4 text-slate-400" /> Unmute
                  <% else %>
                    <.icon name="hero-bell-slash" class="w-4 h-4 text-slate-400" /> Mute
                  <% end %>
                </button>
                <button
                  type="button"
                  phx-click="toggle"
                  class="block w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50"
                >
                  {if @monitor.enabled, do: "Pause", else: "Enable"}
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  data-confirm="Are you sure you want to delete this monitor?"
                  class="block w-full text-left px-4 py-2 text-sm text-red-600 hover:bg-red-50"
                >
                  Delete
                </button>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Uptime status --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-3">Uptime</h2>
        <.uptime_line
          days={Map.get(@daily_status, @monitor.id, [])}
          label={"Last #{@status_days} days"}
        />
      </div>

      <%!-- Ping URL card --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-3">Ping URL</h2>
        <div class="flex items-center gap-2 bg-slate-50 rounded-lg p-3">
          <code class="flex-1 text-sm text-slate-800 font-mono break-all">{@ping_url}</code>
          <button
            type="button"
            id="copy-ping-url"
            phx-hook=".CopyToClipboard"
            data-clipboard-text={@ping_url}
            class="shrink-0 text-slate-400 hover:text-emerald-600 p-1.5 rounded transition-colors"
            title="Copy to clipboard"
          >
            <.icon name="hero-clipboard-document" class="w-5 h-5" />
          </button>
        </div>
        <div class="mt-3 text-sm text-slate-500">
          <p class="mb-1">Add this to the end of your cron job:</p>
          <code class="block bg-slate-800 text-emerald-400 rounded-lg p-3 text-xs font-mono overflow-x-auto">
            curl -fsS --retry 3 {@ping_url}
          </code>
        </div>
      </div>

      <%!-- Details --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">Details</h2>
        <dl class="grid grid-cols-2 gap-4">
          <div>
            <dt class="text-sm text-slate-500">Schedule</dt>
            <dd class="text-sm font-medium text-slate-900 mt-0.5">{format_schedule(@monitor)}</dd>
          </div>
          <div>
            <dt class="text-sm text-slate-500">Grace Period</dt>
            <dd class="text-sm font-medium text-slate-900 mt-0.5">{format_grace(@monitor)}</dd>
          </div>
          <div>
            <dt class="text-sm text-slate-500">Last Ping</dt>
            <dd class="text-sm font-medium text-slate-900 mt-0.5">
              <%= if @monitor.last_ping_at do %>
                <.local_time id="monitor-last-ping" datetime={@monitor.last_ping_at} />
              <% else %>
                Never
              <% end %>
            </dd>
          </div>
          <div>
            <dt class="text-sm text-slate-500">Next Expected</dt>
            <dd class="text-sm font-medium text-slate-900 mt-0.5">
              <%= if @monitor.next_expected_at do %>
                <.local_time id="monitor-next-expected" datetime={@monitor.next_expected_at} />
              <% else %>
                Awaiting first ping
              <% end %>
            </dd>
          </div>
        </dl>
      </div>

      <%!-- Public Badge --%>
      <div class="glass-card rounded-2xl p-6 mb-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-3">
          Public Badge
        </h2>
        <%= if @monitor.badge_token do %>
          <div class="space-y-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class="inline-flex items-center gap-1 text-xs font-medium px-2 py-0.5 rounded bg-emerald-100 text-emerald-700">
                  Enabled
                </span>
                <span class="text-sm text-slate-500">Badge is publicly accessible</span>
              </div>
              <button
                type="button"
                phx-click="disable_badge"
                class="text-sm text-red-600 hover:text-red-700 cursor-pointer"
              >
                Disable
              </button>
            </div>
            <div>
              <p class="text-xs text-slate-500 uppercase mb-2">Status badge</p>
              <div class="flex items-center gap-3 mb-2">
                <img src={"https://#{@host}/badge/monitor/#{@monitor.badge_token}/status.svg"} alt="Status badge" class="h-5" />
              </div>
              <div class="bg-slate-100 rounded p-2">
                <code class="text-xs text-slate-700 break-all select-all">![Status](https://{@host}/badge/monitor/{@monitor.badge_token}/status.svg)</code>
              </div>
            </div>
            <div>
              <p class="text-xs text-slate-500 uppercase mb-2">Uptime bars</p>
              <div class="flex items-center gap-3 mb-2">
                <img src={"https://#{@host}/badge/monitor/#{@monitor.badge_token}/uptime.svg"} alt="Uptime badge" class="h-5" />
              </div>
              <div class="bg-slate-100 rounded p-2">
                <code class="text-xs text-slate-700 break-all select-all">![Uptime](https://{@host}/badge/monitor/{@monitor.badge_token}/uptime.svg)</code>
              </div>
            </div>
          </div>
        <% else %>
          <div class="flex items-center justify-between">
            <p class="text-sm text-slate-500">
              Enable a public badge to embed status in READMEs or status pages.
            </p>
            <button
              type="button"
              phx-click="enable_badge"
              class="px-3 py-1.5 text-sm font-medium text-emerald-700 bg-emerald-50 hover:bg-emerald-100 rounded-md transition-colors cursor-pointer"
            >
              Enable Badge
            </button>
          </div>
        <% end %>
      </div>

      <%!-- Event Log --%>
      <div class="glass-card rounded-2xl p-6">
        <h2 class="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">Availability</h2>
        <%= if @timeline == [] do %>
          <p class="text-sm text-slate-400 text-center py-4">No events yet</p>
        <% else %>
          <div class="divide-y divide-slate-100">
            <%= for {event, idx} <- Enum.with_index(@timeline) do %>
              <%= if event.type == :up do %>
                <div class="py-3 flex items-center gap-3">
                  <span class="w-2 h-2 rounded-full bg-emerald-500 shrink-0" />
                  <div class="flex-1 min-w-0">
                    <span class="text-sm font-medium text-slate-900">Up</span>
                    <span class="text-xs text-slate-400 ml-2">
                      {format_period_duration(event.from, event.to)}
                    </span>
                  </div>
                  <span class="text-xs text-slate-400 shrink-0">
                    <.local_time id={"event-from-#{idx}"} datetime={event.from} />
                    <span class="mx-1">&ndash;</span>
                    <.local_time id={"event-to-#{idx}"} datetime={event.to} />
                  </span>
                </div>
              <% else %>
                <div class="py-3 flex items-center gap-3 bg-red-50/50 -mx-6 px-6">
                  <span class="w-2 h-2 rounded-full bg-red-500 shrink-0" />
                  <div class="flex-1 min-w-0">
                    <span class="text-sm font-medium text-red-700">Down</span>
                    <span class="text-xs text-red-500 ml-2">
                      {format_gap_duration(event.duration_minutes)}
                    </span>
                  </div>
                  <span class="text-xs text-red-400 shrink-0">
                    <.local_time id={"event-from-#{idx}"} datetime={event.from} />
                    <span class="mx-1">&ndash;</span>
                    <.local_time id={"event-to-#{idx}"} datetime={event.to} />
                  </span>
                </div>
              <% end %>
            <% end %>
          </div>
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const text = this.el.getAttribute("data-clipboard-text")
              if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(text).then(() => this.flash())
              } else {
                const ta = document.createElement("textarea")
                ta.value = text
                ta.style.position = "fixed"
                ta.style.left = "-9999px"
                document.body.appendChild(ta)
                ta.select()
                document.execCommand("copy")
                document.body.removeChild(ta)
                this.flash()
              }
            })
          },
          flash() {
            if (this.el.dataset.copied) return
            this.el.dataset.copied = "true"
            const icon = this.el.querySelector("span")
            const originalClass = icon ? icon.getAttribute("class") : null
            if (icon) {
              icon.setAttribute("class", originalClass.replace("hero-clipboard-document", "hero-check"))
              icon.style.color = "#10b981"
            }
            const tip = document.createElement("span")
            tip.textContent = "Copied!"
            tip.style.cssText = "position:absolute;bottom:100%;left:50%;transform:translateX(-50%);margin-bottom:6px;padding:4px 10px;background:#0f172a;color:white;font-size:12px;border-radius:6px;white-space:nowrap;pointer-events:none;z-index:50"
            this.el.style.position = "relative"
            this.el.appendChild(tip)
            setTimeout(() => {
              if (icon && originalClass) {
                icon.setAttribute("class", originalClass)
                icon.style.color = ""
              }
              tip.remove()
              delete this.el.dataset.copied
            }, 1500)
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
