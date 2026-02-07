defmodule PrikkeWeb.MonitorLive.Index do
  use PrikkeWeb, :live_view

  alias Prikke.Monitors

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      if connected?(socket) do
        Monitors.subscribe_monitors(org)
      end

      monitors = Monitors.list_monitors(org)
      status_days = if org.tier == "pro", do: 30, else: 7
      daily_status = Monitors.get_daily_status(monitors, status_days)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Monitors")
       |> assign(:monitors, monitors)
       |> assign(:status_days, status_days)
       |> assign(:daily_status, daily_status)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_info({:monitor_created, monitor}, socket) do
    monitors = [monitor | socket.assigns.monitors]
    daily_status = Monitors.get_daily_status(monitors, socket.assigns.status_days)

    {:noreply,
     socket
     |> assign(:monitors, monitors)
     |> assign(:daily_status, daily_status)}
  end

  def handle_info({:monitor_updated, monitor}, socket) do
    monitors = Enum.map(socket.assigns.monitors, fn m -> if m.id == monitor.id, do: monitor, else: m end)
    daily_status = Monitors.get_daily_status(monitors, socket.assigns.status_days)

    {:noreply,
     socket
     |> assign(:monitors, monitors)
     |> assign(:daily_status, daily_status)}
  end

  def handle_info({:monitor_deleted, monitor}, socket) do
    monitors = Enum.reject(socket.assigns.monitors, fn m -> m.id == monitor.id end)
    daily_status = Monitors.get_daily_status(monitors, socket.assigns.status_days)

    {:noreply,
     socket
     |> assign(:monitors, monitors)
     |> assign(:daily_status, daily_status)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    monitor = Monitors.get_monitor!(socket.assigns.organization, id)
    {:ok, _} = Monitors.delete_monitor(socket.assigns.organization, monitor)
    {:noreply, put_flash(socket, :info, "Monitor deleted")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    monitor = Monitors.get_monitor!(socket.assigns.organization, id)
    {:ok, _} = Monitors.toggle_monitor(socket.assigns.organization, monitor)
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

  defp uptime_line(%{days: []} = assigns) do
    ~H"""
    <div class="flex items-center gap-0.5 pl-5">
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
    <div class="flex items-center gap-0.5 pl-5">
      <div class="flex items-center gap-px flex-1">
        <%= for {{date, %{status: status, actual: actual, expected: expected}}, idx} <- Enum.with_index(@days) do %>
          <div class="flex-1 group relative">
            <div class={["h-3 first:rounded-l-sm last:rounded-r-sm", day_status_color(status)]} />
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
      <span class="text-xs text-slate-400 ml-2 shrink-0 tabular-nums w-20 text-right">
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

  defp status_dot_color("up"), do: "bg-emerald-500"
  defp status_dot_color("down"), do: "bg-red-500"
  defp status_dot_color("new"), do: "bg-slate-400"
  defp status_dot_color("paused"), do: "bg-amber-400"
  defp status_dot_color(_), do: "bg-slate-300"

  defp status_label("up"), do: "Up"
  defp status_label("down"), do: "Down"
  defp status_label("new"), do: "Awaiting first ping"
  defp status_label("paused"), do: "Paused"
  defp status_label(_), do: "Unknown"

  defp format_schedule(%{schedule_type: "cron", cron_expression: expr}), do: expr
  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}) when s < 120, do: "Every #{s}s"
  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}) when s < 7200, do: "Every #{div(s, 60)}m"
  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}) when s < 172_800, do: "Every #{div(s, 3600)}h"
  defp format_schedule(%{schedule_type: "interval", interval_seconds: s}), do: "Every #{div(s, 86400)}d"
  defp format_schedule(_), do: ""

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
            <h1 class="text-xl sm:text-2xl font-bold text-slate-900">Monitors</h1>
            <p class="text-slate-500 mt-1 text-sm">Heartbeat monitoring for your external cron jobs</p>
          </div>
          <.link
            navigate={~p"/monitors/new"}
            class="text-sm font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-3 sm:px-4 py-2 rounded-md transition-colors no-underline whitespace-nowrap"
          >
            New Monitor
          </.link>
        </div>

        <%= if @monitors == [] do %>
          <div class="glass-card rounded-2xl p-8 sm:p-12 text-center">
            <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-4">
              <.icon name="hero-heart" class="w-6 h-6 text-slate-400" />
            </div>
            <h3 class="text-lg font-medium text-slate-900 mb-2">No monitors yet</h3>
            <p class="text-slate-500 mb-6">
              Create a monitor to track your external cron jobs. We'll alert you if a ping is missed.
            </p>
            <.link navigate={~p"/monitors/new"} class="text-emerald-600 font-medium hover:underline">
              Create a monitor
            </.link>
          </div>
        <% else %>
          <div class="glass-card rounded-2xl divide-y divide-slate-200/60">
            <%= for monitor <- @monitors do %>
              <div class="px-4 sm:px-6 py-5">
                <div class="flex items-start sm:items-center justify-between gap-3">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 sm:gap-3 flex-wrap">
                      <span class={["w-2.5 h-2.5 rounded-full shrink-0", status_dot_color(monitor.status)]}
                            title={status_label(monitor.status)} />
                      <.link
                        navigate={~p"/monitors/#{monitor.id}"}
                        class="font-medium text-slate-900 hover:text-emerald-600 break-all sm:truncate"
                      >
                        {monitor.name}
                      </.link>
                      <%= if monitor.muted do %>
                        <span title="Notifications muted">
                          <.icon name="hero-bell-slash" class="w-4 h-4 text-slate-400" />
                        </span>
                      <% end %>
                      <span class={[
                        "text-xs font-medium px-2 py-0.5 rounded",
                        monitor.status == "up" && "bg-emerald-100 text-emerald-700",
                        monitor.status == "down" && "bg-red-100 text-red-700",
                        monitor.status == "new" && "bg-slate-100 text-slate-600",
                        monitor.status == "paused" && "bg-amber-100 text-amber-700"
                      ]}>
                        {status_label(monitor.status)}
                      </span>
                    </div>
                    <div class="text-xs sm:text-sm text-slate-400 mt-1">
                      <span class="font-mono">{format_schedule(monitor)}</span>
                      <%= if monitor.last_ping_at do %>
                        <span class="text-slate-300 ml-1">·</span>
                        <span class="ml-1">
                          Last ping: <.local_time
                            id={"mon-#{monitor.id}-last-ping"}
                            datetime={monitor.last_ping_at}
                          />
                        </span>
                      <% end %>
                    </div>
                  </div>
                  <div class="flex items-center gap-2 sm:gap-3 shrink-0">
                    <button
                      type="button"
                      phx-click="toggle"
                      phx-value-id={monitor.id}
                      class={[
                        "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:ring-offset-2",
                        monitor.enabled && "bg-emerald-600",
                        !monitor.enabled && "bg-slate-200"
                      ]}
                    >
                      <span class={[
                        "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                        monitor.enabled && "translate-x-5",
                        !monitor.enabled && "translate-x-0"
                      ]} />
                    </button>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={monitor.id}
                      data-confirm="Are you sure you want to delete this monitor?"
                      class="text-slate-400 hover:text-red-600 p-1"
                    >
                      <.icon name="hero-trash" class="w-5 h-5" />
                    </button>
                  </div>
                </div>
                <.link navigate={~p"/monitors/#{monitor.id}"} class="block">
                  <.uptime_line
                    days={Map.get(@daily_status, monitor.id, [])}
                    label={"Last #{@status_days} days"}
                  />
                </.link>
              </div>
            <% end %>
          </div>
        <% end %>
    </Layouts.app>
    """
  end
end
