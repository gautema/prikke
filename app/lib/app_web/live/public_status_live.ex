defmodule PrikkeWeb.PublicStatusLive do
  use PrikkeWeb, :live_view

  alias Prikke.StatusPages
  alias Prikke.Executions
  alias Prikke.Monitors
  alias Prikke.Endpoints

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case StatusPages.get_public_status_page(slug) do
      nil ->
        {:ok,
         socket
         |> assign(:page_title, "Not Found")
         |> assign(:status_page, nil)
         |> assign(:hide_header, true)
         |> assign(:hide_footer, true)}

      status_page ->
        resources = StatusPages.list_visible_resources(status_page.organization)
        task_data = load_task_data(resources.tasks)
        monitor_data = load_monitor_data(resources.monitors)
        endpoint_data = load_endpoint_data(resources.endpoints)

        overall = compute_overall_status(task_data, monitor_data, endpoint_data)

        {:ok,
         socket
         |> assign(:page_title, status_page.title)
         |> assign(:status_page, status_page)
         |> assign(:task_data, task_data)
         |> assign(:monitor_data, monitor_data)
         |> assign(:endpoint_data, endpoint_data)
         |> assign(:overall, overall)
         |> assign(:hide_header, true)
         |> assign(:hide_footer, true)}
    end
  end

  @impl true
  def render(%{status_page: nil} = assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center">
      <div class="text-center">
        <h1 class="text-2xl font-bold text-slate-900 mb-2">Status page not found</h1>
        <p class="text-slate-500">This status page doesn't exist or has been disabled.</p>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-50 to-white">
      <div class="max-w-3xl mx-auto px-4 py-8 sm:py-12">
        <%!-- Header --%>
        <div class="text-center mb-8">
          <h1 class="text-2xl sm:text-3xl font-bold text-slate-900">{@status_page.title}</h1>
          <%= if @status_page.description && @status_page.description != "" do %>
            <p class="text-slate-500 mt-2 max-w-xl mx-auto">{@status_page.description}</p>
          <% end %>
        </div>

        <%!-- Overall Status Banner --%>
        <div class={[
          "rounded-2xl p-6 mb-8 text-center",
          overall_banner_class(@overall)
        ]}>
          <div class="flex items-center justify-center gap-2">
            <span class={["w-3 h-3 rounded-full", overall_dot_class(@overall)]} />
            <span class="text-lg font-semibold">{overall_label(@overall)}</span>
          </div>
        </div>

        <%!-- Resources --%>
        <div class="space-y-3">
          <%= for {task, status_label, daily_status} <- @task_data do %>
            <div class="bg-white rounded-xl border border-slate-200 p-4">
              <div class="flex items-center justify-between mb-2">
                <div class="flex items-center gap-2">
                  <span class={["w-2 h-2 rounded-full shrink-0", status_dot(status_label)]} />
                  <span class="text-sm font-medium text-slate-900">{task.name}</span>
                  <span class="text-xs text-slate-400">Task</span>
                </div>
                <span class={["text-xs font-medium px-2 py-0.5 rounded", status_pill(status_label)]}>
                  {status_label}
                </span>
              </div>
              <%= if daily_status != [] do %>
                <.task_bars days={daily_status} />
              <% end %>
            </div>
          <% end %>

          <%= for {monitor, status_label, daily_status} <- @monitor_data do %>
            <div class="bg-white rounded-xl border border-slate-200 p-4">
              <div class="flex items-center justify-between mb-2">
                <div class="flex items-center gap-2">
                  <span class={["w-2 h-2 rounded-full shrink-0", status_dot(status_label)]} />
                  <span class="text-sm font-medium text-slate-900">{monitor.name}</span>
                  <span class="text-xs text-slate-400">Monitor</span>
                </div>
                <span class={["text-xs font-medium px-2 py-0.5 rounded", status_pill(status_label)]}>
                  {status_label}
                </span>
              </div>
              <%= if daily_status != [] do %>
                <.monitor_bars days={daily_status} />
              <% end %>
            </div>
          <% end %>

          <%= for {endpoint, status_label} <- @endpoint_data do %>
            <div class="bg-white rounded-xl border border-slate-200 p-4">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span class={["w-2 h-2 rounded-full shrink-0", status_dot(status_label)]} />
                  <span class="text-sm font-medium text-slate-900">{endpoint.name}</span>
                  <span class="text-xs text-slate-400">Endpoint</span>
                </div>
                <span class={["text-xs font-medium px-2 py-0.5 rounded", status_pill(status_label)]}>
                  {status_label}
                </span>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Footer --%>
        <div class="mt-12 text-center">
          <a
            href="https://runlater.eu"
            target="_blank"
            class="text-xs text-slate-400 hover:text-slate-500 transition-colors"
          >
            Powered by Runlater
          </a>
        </div>
      </div>
    </div>
    """
  end

  defp task_bars(assigns) do
    ~H"""
    <div>
      <div class="flex gap-0.5">
        <%= for {date, %{status: status, total: total, failed: failed}} <- @days do %>
          <div
            class={[
              "flex-1 h-8 rounded-sm transition-opacity hover:opacity-80",
              task_bar_color(status)
            ]}
            title={"#{Calendar.strftime(date, "%d %b %Y")}: #{task_day_label(status, total, failed)}"}
          />
        <% end %>
      </div>
      <div class="flex justify-between mt-2 text-xs text-slate-400">
        <span>30 days ago</span>
        <span>Today</span>
      </div>
    </div>
    """
  end

  defp monitor_bars(assigns) do
    ~H"""
    <div>
      <div class="flex gap-0.5">
        <%= for {date, %{status: status}} <- @days do %>
          <div
            class={[
              "flex-1 h-8 rounded-sm transition-opacity hover:opacity-80",
              day_bar_color(status)
            ]}
            title={"#{Calendar.strftime(date, "%d %b %Y")}: #{day_status_label(status)}"}
          />
        <% end %>
      </div>
      <div class="flex justify-between mt-2 text-xs text-slate-400">
        <span>30 days ago</span>
        <span>Today</span>
      </div>
    </div>
    """
  end

  # Data loading

  defp load_task_data(tasks) do
    Enum.map(tasks, fn task ->
      daily_status = Executions.get_daily_status_for_task(task, 30)
      {label, _color} = task_status(task)
      {task, label, daily_status}
    end)
  end

  defp load_monitor_data(monitors) do
    Enum.map(monitors, fn monitor ->
      daily_status = Monitors.get_daily_status([monitor], 30) |> Map.get(monitor.id, [])
      {label, _color} = monitor_status(monitor)
      {monitor, label, daily_status}
    end)
  end

  defp load_endpoint_data(endpoints) do
    Enum.map(endpoints, fn endpoint ->
      last_status = Endpoints.get_last_event_status(endpoint)
      {label, _color} = endpoint_status(endpoint, last_status)
      {endpoint, label}
    end)
  end

  # Status resolution (same logic as Badges module)

  defp task_status(%{enabled: false}), do: {"paused", "#94a3b8"}

  defp task_status(%{last_execution_status: status}) do
    case status do
      "success" -> {"passing", "#10b981"}
      "failed" -> {"failing", "#ef4444"}
      "timeout" -> {"timeout", "#f97316"}
      "running" -> {"running", "#3b82f6"}
      _ -> {"unknown", "#94a3b8"}
    end
  end

  defp monitor_status(%{enabled: false}), do: {"paused", "#94a3b8"}

  defp monitor_status(%{status: status}) do
    case status do
      "up" -> {"up", "#10b981"}
      "down" -> {"down", "#ef4444"}
      "degraded" -> {"degraded", "#f97316"}
      _ -> {"new", "#94a3b8"}
    end
  end

  defp endpoint_status(%{enabled: false}, _), do: {"disabled", "#94a3b8"}

  defp endpoint_status(_endpoint, last_status) do
    case last_status do
      "success" -> {"passing", "#10b981"}
      "failed" -> {"failing", "#ef4444"}
      "timeout" -> {"timeout", "#f97316"}
      _ -> {"no data", "#94a3b8"}
    end
  end

  # Overall status computation

  defp compute_overall_status(task_data, monitor_data, endpoint_data) do
    statuses =
      Enum.map(task_data, fn {_, label, _} -> label end) ++
        Enum.map(monitor_data, fn {_, label, _} -> label end) ++
        Enum.map(endpoint_data, fn {_, label} -> label end)

    cond do
      statuses == [] -> :operational
      Enum.any?(statuses, &(&1 in ["failing", "down"])) -> :major_outage
      Enum.any?(statuses, &(&1 in ["timeout", "degraded"])) -> :partial_outage
      true -> :operational
    end
  end

  # UI helpers

  defp overall_banner_class(:operational), do: "bg-emerald-50 text-emerald-800"
  defp overall_banner_class(:partial_outage), do: "bg-amber-50 text-amber-800"
  defp overall_banner_class(:major_outage), do: "bg-red-50 text-red-800"

  defp overall_dot_class(:operational), do: "bg-emerald-500"
  defp overall_dot_class(:partial_outage), do: "bg-amber-500"
  defp overall_dot_class(:major_outage), do: "bg-red-500"

  defp overall_label(:operational), do: "All systems operational"
  defp overall_label(:partial_outage), do: "Partial outage"
  defp overall_label(:major_outage), do: "Major outage"

  defp status_dot("passing"), do: "bg-emerald-500"
  defp status_dot("up"), do: "bg-emerald-500"
  defp status_dot("failing"), do: "bg-red-500"
  defp status_dot("down"), do: "bg-red-500"
  defp status_dot("timeout"), do: "bg-orange-500"
  defp status_dot("degraded"), do: "bg-orange-500"
  defp status_dot(_), do: "bg-slate-300"

  defp status_pill("passing"), do: "bg-emerald-100 text-emerald-700"
  defp status_pill("up"), do: "bg-emerald-100 text-emerald-700"
  defp status_pill("failing"), do: "bg-red-100 text-red-700"
  defp status_pill("down"), do: "bg-red-100 text-red-700"
  defp status_pill("timeout"), do: "bg-orange-100 text-orange-700"
  defp status_pill("degraded"), do: "bg-orange-100 text-orange-700"
  defp status_pill(_), do: "bg-slate-100 text-slate-600"

  defp task_bar_color("success"), do: "bg-emerald-600"
  defp task_bar_color("failed"), do: "bg-red-500"
  defp task_bar_color(_), do: "bg-slate-200"

  defp task_day_label("none", _, _), do: "No executions"
  defp task_day_label("success", total, _), do: "All #{total} passed"
  defp task_day_label("failed", total, failed), do: "#{failed} of #{total} failed"
  defp task_day_label(_, _, _), do: "No data"

  defp day_bar_color("up"), do: "bg-emerald-600"
  defp day_bar_color("degraded"), do: "bg-amber-500"
  defp day_bar_color("down"), do: "bg-red-500"
  defp day_bar_color(_), do: "bg-slate-200"

  defp day_status_label("up"), do: "Operational"
  defp day_status_label("degraded"), do: "Degraded"
  defp day_status_label("down"), do: "Down"
  defp day_status_label(_), do: "No data"
end
