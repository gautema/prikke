defmodule PrikkeWeb.DashboardLive do
  use PrikkeWeb, :live_view

  alias Prikke.Accounts
  alias Prikke.Jobs
  alias Prikke.Executions
  alias Prikke.Monitors
  alias Prikke.Cron

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user

    organizations = Accounts.list_user_organizations(user)
    pending_invites = Accounts.list_pending_invites_for_email(user.email)

    org_id = session["current_organization_id"]

    current_org =
      if org_id do
        Enum.find(organizations, &(&1.id == org_id))
      end

    current_org = current_org || List.first(organizations)

    # Subscribe to job, execution, and monitor updates if we have an organization
    if current_org && connected?(socket) do
      Jobs.subscribe_jobs(current_org)
      Executions.subscribe_organization_executions(current_org.id)
      Monitors.subscribe_monitors(current_org)
    end

    recent_jobs = load_recent_jobs(current_org)
    job_ids = Enum.map(recent_jobs, & &1.id)
    latest_statuses = Executions.get_latest_statuses(job_ids)
    {monitors, monitor_trend} = load_monitors_data(current_org)

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:current_organization, current_org)
      |> assign(:organizations, organizations)
      |> assign(:pending_invites_count, length(pending_invites))
      |> assign(:stats, load_stats(current_org))
      |> assign(:recent_jobs, recent_jobs)
      |> assign(:latest_statuses, latest_statuses)
      |> assign(:monitors, monitors)
      |> assign(:monitor_trend, monitor_trend)

    {:ok, socket}
  end

  @impl true
  def handle_info({:created, _job}, socket) do
    org = socket.assigns.current_organization
    {:noreply, reload_data(socket, org)}
  end

  def handle_info({:updated, _job}, socket) do
    org = socket.assigns.current_organization
    {:noreply, reload_data(socket, org)}
  end

  def handle_info({:deleted, _job}, socket) do
    org = socket.assigns.current_organization
    {:noreply, reload_data(socket, org)}
  end

  def handle_info({:execution_updated, _execution}, socket) do
    org = socket.assigns.current_organization
    {:noreply, reload_data(socket, org)}
  end

  def handle_info({:monitor_updated, _monitor}, socket) do
    {monitors, monitor_trend} = load_monitors_data(socket.assigns.current_organization)
    {:noreply, socket |> assign(:monitors, monitors) |> assign(:monitor_trend, monitor_trend)}
  end

  def handle_info({:monitor_created, _monitor}, socket) do
    {monitors, monitor_trend} = load_monitors_data(socket.assigns.current_organization)
    {:noreply, socket |> assign(:monitors, monitors) |> assign(:monitor_trend, monitor_trend)}
  end

  def handle_info({:monitor_deleted, _monitor}, socket) do
    {monitors, monitor_trend} = load_monitors_data(socket.assigns.current_organization)
    {:noreply, socket |> assign(:monitors, monitors) |> assign(:monitor_trend, monitor_trend)}
  end

  defp reload_data(socket, org) do
    recent_jobs = load_recent_jobs(org)
    job_ids = Enum.map(recent_jobs, & &1.id)
    latest_statuses = Executions.get_latest_statuses(job_ids)
    {monitors, monitor_trend} = load_monitors_data(org)

    socket
    |> assign(:stats, load_stats(org))
    |> assign(:recent_jobs, recent_jobs)
    |> assign(:latest_statuses, latest_statuses)
    |> assign(:monitors, monitors)
    |> assign(:monitor_trend, monitor_trend)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">
      <div class="mb-8 flex justify-between items-start">
        <div>
          <h1 class="text-2xl font-bold text-slate-900">Dashboard</h1>
          <%= if @current_organization do %>
            <div class="flex items-center gap-2 mt-1">
              <span class="text-slate-500">{@current_organization.name}</span>
              <span class="text-xs font-medium text-slate-400 bg-slate-100 px-2 py-0.5 rounded">
                {String.capitalize(@current_organization.tier)}
              </span>
              <%= if length(@organizations) > 1 do %>
                <span class="text-slate-300">·</span>
                <a href={~p"/organizations"} class="text-sm text-emerald-600 hover:underline">
                  Switch
                </a>
              <% end %>
            </div>
          <% else %>
            <p class="text-slate-500 mt-1">
              <a href={~p"/organizations/new"} class="text-emerald-600 hover:underline">
                Create an organization
              </a>
              to get started
            </p>
          <% end %>
        </div>
      </div>

      <%= if @current_organization do %>
        <!-- Monthly Usage -->
        <div class="glass-card rounded-2xl p-4 mb-4">
          <div class="flex justify-between items-center mb-2">
            <span class="text-sm font-medium text-slate-600">Monthly Executions</span>
            <span class="text-sm text-slate-500">
              {format_number(@stats.monthly_executions)} / {format_number(@stats.monthly_limit)}
            </span>
          </div>
          <div class="w-full bg-slate-100 rounded-full h-2">
            <div
              class={[
                "h-2 rounded-full transition-all",
                usage_bar_color(@stats.monthly_executions, @stats.monthly_limit)
              ]}
              style={"width: #{min(usage_percent(@stats.monthly_executions, @stats.monthly_limit), 100)}%"}
            >
            </div>
          </div>
          <%= if usage_percent(@stats.monthly_executions, @stats.monthly_limit) >= 80 do %>
            <p class={[
              "text-xs mt-2",
              if(usage_percent(@stats.monthly_executions, @stats.monthly_limit) >= 100,
                do: "text-red-600",
                else: "text-amber-600"
              )
            ]}>
              <%= if usage_percent(@stats.monthly_executions, @stats.monthly_limit) >= 100 do %>
                Monthly limit reached. Jobs will be skipped until next month.
                <%= if @current_organization.tier == "free" do %>
                  <.link navigate={~p"/organizations/settings"} class="underline">
                    Upgrade to Pro
                  </.link>
                <% else %>
                  <a href="mailto:support@runlater.eu" class="underline">Contact us</a>
                  for higher limits.
                <% end %>
              <% else %>
                Approaching monthly limit.
                <%= if @current_organization.tier == "free" do %>
                  <.link navigate={~p"/organizations/settings"} class="underline">
                    Upgrade to Pro
                  </.link>
                  for 250k executions.
                <% else %>
                  <a href="mailto:support@runlater.eu" class="underline">Contact us</a>
                  for higher limits.
                <% end %>
              <% end %>
            </p>
          <% end %>
        </div>

        <!-- Quick Stats -->
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-4">
          <.link
            navigate={~p"/jobs"}
            class="glass-card rounded-2xl p-6 hover:border-slate-300 transition-colors"
          >
            <div class="text-sm font-medium text-slate-500 mb-1">Active Jobs</div>
            <div class="text-3xl font-bold text-slate-900">{@stats.active_jobs}</div>
          </.link>
          <div class="glass-card rounded-2xl p-6">
            <div class="text-sm font-medium text-slate-500 mb-1">Executions Today</div>
            <div class="text-3xl font-bold text-slate-900">{@stats.executions_today}</div>
            <%= if @stats.today_failed > 0 do %>
              <div class="text-xs text-red-600 mt-1">{@stats.today_failed} failed</div>
            <% end %>
          </div>
          <div class="glass-card rounded-2xl p-6">
            <div class="text-sm font-medium text-slate-500 mb-1">Success Rate</div>
            <div class="text-3xl font-bold text-emerald-600">{@stats.success_rate}</div>
            <%= if @stats.success_rate_7d != "—" do %>
              <div class="text-xs text-slate-400 mt-1">7d: {@stats.success_rate_7d}</div>
            <% end %>
          </div>
          <div class="glass-card rounded-2xl p-6">
            <div class="text-sm font-medium text-slate-500 mb-1">Avg Duration</div>
            <div class="text-3xl font-bold text-slate-900">
              {format_avg_duration(@stats.avg_duration_ms)}
            </div>
            <div class="text-xs text-slate-400 mt-1">today</div>
          </div>
        </div>

        <!-- Jobs Section -->
        <div class="glass-card rounded-2xl mb-4">
          <div class="px-6 py-4 border-b border-white/50 flex flex-col sm:flex-row sm:justify-between sm:items-center gap-2">
            <div class="flex items-center gap-3">
              <h2 class="text-lg font-semibold text-slate-900">Jobs</h2>
              <.job_summary stats={@stats} />
            </div>
            <div class="flex gap-2">
              <.link
                navigate={~p"/queue"}
                class="text-sm font-medium text-slate-700 bg-slate-100 hover:bg-slate-200 px-4 py-2 rounded-md transition-colors no-underline flex items-center gap-1.5"
              >
                <.icon name="hero-bolt" class="w-4 h-4" /> Queue
              </.link>
              <.link
                navigate={~p"/jobs/new"}
                class="text-sm font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-4 py-2 rounded-md transition-colors no-underline"
              >
                New Job
              </.link>
            </div>
          </div>
          <%= if @recent_jobs == [] do %>
            <div class="p-8 text-center">
              <p class="text-slate-500 mb-2">No jobs yet.</p>
              <.link navigate={~p"/jobs/new"} class="text-emerald-600 text-sm font-medium hover:underline">
                Create your first job →
              </.link>
            </div>
          <% else %>
            <!-- Execution Trend -->
            <.execution_trend trend={@stats.execution_trend} days={@stats.trend_days} />
            <!-- Job List -->
            <div class="divide-y divide-white/30">
              <%= for job <- @recent_jobs do %>
                <.link
                  navigate={~p"/jobs/#{job.id}"}
                  class="block px-6 py-3 hover:bg-white/50 transition-colors"
                >
                  <div class="flex items-center justify-between">
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <.execution_status_dot status={get_status(@latest_statuses[job.id])} />
                        <span class="text-sm text-slate-900 truncate">{job.name}</span>
                        <.job_status_badge job={job} latest_info={@latest_statuses[job.id]} />
                      </div>
                    </div>
                    <div class="text-xs text-slate-400 ml-4 text-right shrink-0">
                      <%= if job.schedule_type == "cron" do %>
                        {Cron.describe(job.cron_expression)}
                      <% else %>
                        One-time
                      <% end %>
                    </div>
                  </div>
                </.link>
              <% end %>
            </div>
            <div class="px-6 py-3 border-t border-slate-200 text-center">
              <.link navigate={~p"/jobs"} class="text-sm text-emerald-600 hover:underline">
                View all jobs →
              </.link>
            </div>
          <% end %>
        </div>

        <!-- Monitors Section -->
        <div class="glass-card rounded-2xl mb-4">
          <div class="px-6 py-4 border-b border-white/50 flex flex-col sm:flex-row sm:justify-between sm:items-center gap-2">
            <div class="flex items-center gap-3">
              <h2 class="text-lg font-semibold text-slate-900">Monitors</h2>
              <%= if @monitors != [] do %>
                <.monitor_summary monitors={@monitors} />
              <% end %>
            </div>
            <.link
              navigate={~p"/monitors/new"}
              class="text-sm font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-4 py-2 rounded-md transition-colors no-underline w-fit"
            >
              New Monitor
            </.link>
          </div>
          <%= if @monitors == [] do %>
            <div class="p-8 text-center">
              <p class="text-slate-500 mb-2">No monitors yet.</p>
              <.link navigate={~p"/monitors/new"} class="text-emerald-600 text-sm font-medium hover:underline">
                Set up heartbeat monitoring →
              </.link>
            </div>
          <% else %>
            <!-- Monitor Uptime Trend -->
            <.monitor_trend trend={@monitor_trend} />
            <!-- Monitor List -->
            <div class="divide-y divide-white/30">
              <%= for monitor <- @monitors do %>
                <.link
                  navigate={~p"/monitors/#{monitor.id}"}
                  class="block px-6 py-3 hover:bg-white/50 transition-colors"
                >
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class={["w-2.5 h-2.5 rounded-full shrink-0", monitor_dot_color(monitor.status)]} />
                      <span class="text-sm text-slate-900 truncate">{monitor.name}</span>
                      <span class={[
                        "text-xs font-medium px-2 py-0.5 rounded",
                        monitor.status == "down" && "bg-red-100 text-red-700",
                        monitor.status == "up" && "bg-emerald-100 text-emerald-700",
                        monitor.status == "new" && "bg-slate-100 text-slate-600",
                        monitor.status == "paused" && "bg-amber-100 text-amber-700"
                      ]}>
                        {monitor_status_label(monitor.status)}
                      </span>
                    </div>
                  </div>
                </.link>
              <% end %>
            </div>
            <div class="px-6 py-3 border-t border-slate-200 text-center">
              <.link navigate={~p"/monitors"} class="text-sm text-emerald-600 hover:underline">
                View all monitors →
              </.link>
            </div>
          <% end %>
        </div>

      <% else %>
        <!-- No organization state -->
        <div class="glass-card rounded-2xl p-12 text-center">
          <div class="w-12 h-12 bg-emerald-100 rounded-full flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-building-office" class="w-6 h-6 text-emerald-600" />
          </div>
          <h3 class="text-lg font-medium text-slate-900 mb-1">Create your first organization</h3>
          <p class="text-slate-500 mb-6">Organizations help you manage jobs and team members.</p>
          <a
            href={~p"/organizations/new"}
            class="inline-block px-6 py-3 bg-emerald-600 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors no-underline"
          >
            Create Organization
          </a>
        </div>
      <% end %>
    </div>
    """
  end

  defp load_stats(nil),
    do: %{
      active_jobs: 0,
      total_jobs: 0,
      executions_today: 0,
      today_failed: 0,
      success_rate: "—",
      success_rate_7d: "—",
      avg_duration_ms: nil,
      monthly_executions: 0,
      monthly_limit: 0,
      trend_days: 7,
      execution_trend: Enum.map(0..6, fn offset ->
        {Date.add(Date.utc_today(), -6 + offset), %{total: 0, success: 0, failed: 0}}
      end)
    }

  defp load_stats(organization) do
    exec_stats = Executions.get_today_stats(organization)
    tier_limits = Jobs.get_tier_limits(organization.tier)
    monthly_executions = Executions.count_current_month_executions(organization)
    trend_days = if organization.tier == "pro", do: 30, else: 7

    seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day)
    stats_7d = Executions.get_organization_stats(organization, since: seven_days_ago)

    success_rate = calculate_success_rate(exec_stats)
    success_rate_7d = calculate_success_rate(stats_7d)

    %{
      active_jobs: Jobs.count_enabled_jobs(organization),
      total_jobs: Jobs.count_jobs(organization),
      executions_today: exec_stats.total,
      today_failed: exec_stats.failed,
      success_rate: success_rate,
      success_rate_7d: success_rate_7d,
      avg_duration_ms: exec_stats.avg_duration_ms,
      monthly_executions: monthly_executions,
      monthly_limit: tier_limits.max_monthly_executions,
      trend_days: trend_days,
      execution_trend: Executions.executions_by_day_for_org(organization, trend_days)
    }
  end

  defp format_avg_duration(nil), do: "—"

  defp format_avg_duration(avg) do
    ms = Decimal.to_float(avg) |> round()

    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{Float.round(ms / 60_000, 1)}m"
    end
  end

  defp calculate_success_rate(%{total: 0}), do: "—"

  defp calculate_success_rate(%{total: total, success: success}) do
    rate = round(success / total * 100)
    "#{rate}%"
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_number(n), do: "#{n}"

  defp usage_percent(_current, 0), do: 0
  defp usage_percent(current, limit), do: round(current / limit * 100)

  defp usage_bar_color(current, limit) do
    percent = usage_percent(current, limit)

    cond do
      percent >= 100 -> "bg-red-500"
      percent >= 80 -> "bg-amber-500"
      true -> "bg-emerald-600"
    end
  end

  defp load_monitors_data(nil), do: {[], []}

  defp load_monitors_data(organization) do
    monitors = Monitors.list_monitors(organization)
    status_days = if organization.tier == "pro", do: 30, else: 7

    monitor_trend =
      if monitors == [] do
        []
      else
        daily_status = Monitors.get_daily_status(monitors, status_days)

        # Aggregate across all monitors: for each day, count up/degraded/down
        today = Date.utc_today()

        Enum.map(0..(status_days - 1), fn offset ->
          date = Date.add(today, -status_days + 1 + offset)

          statuses =
            Enum.map(monitors, fn m ->
              case daily_status[m.id] do
                nil -> "none"
                days -> Enum.find_value(days, "none", fn {d, s} -> if d == date, do: s end)
              end
            end)

          up = Enum.count(statuses, &(&1 == "up"))
          degraded = Enum.count(statuses, &(&1 == "degraded"))
          down = Enum.count(statuses, &(&1 == "down"))
          total = up + degraded + down

          {date, %{up: up, degraded: degraded, down: down, total: total}}
        end)
      end

    {monitors, monitor_trend}
  end

  defp load_recent_jobs(nil), do: []

  defp load_recent_jobs(organization) do
    organization
    |> Jobs.list_jobs()
    |> Enum.take(5)
  end

  defp get_status(nil), do: nil
  defp get_status(%{status: status}), do: status

  defp get_attempt(nil), do: 1
  defp get_attempt(%{attempt: attempt}), do: attempt

  defp job_completed?(job, latest_info) do
    job.schedule_type == "once" and is_nil(job.next_run_at) and
      get_status(latest_info) == "success"
  end

  defp job_status_badge(assigns) do
    status = get_status(assigns.latest_info)
    attempt = get_attempt(assigns.latest_info)
    assigns = assign(assigns, :status, status)
    assigns = assign(assigns, :attempt, attempt)

    ~H"""
    <%= cond do %>
      <% job_completed?(@job, @latest_info) -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-slate-100 text-slate-600">
          Completed
        </span>
      <% @job.schedule_type == "once" and @status in ["failed", "timeout"] -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-red-100 text-red-700">Failed</span>
      <% @job.schedule_type == "once" and @status in ["pending", "running"] and @attempt > 1 -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-amber-100 text-amber-700">
          Retrying ({@attempt}/{@job.retry_attempts})
        </span>
      <% @job.schedule_type == "once" and @status in ["pending", "running"] -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-blue-100 text-blue-700">Running</span>
      <% @job.enabled -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-emerald-100 text-emerald-700">
          Active
        </span>
      <% true -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-amber-100 text-amber-700">
          Paused
        </span>
    <% end %>
    """
  end

  defp execution_status_dot(assigns) do
    ~H"""
    <span
      class={["w-2.5 h-2.5 rounded-full shrink-0", status_dot_color(@status)]}
      title={status_dot_title(@status)}
    />
    """
  end

  defp execution_trend(assigns) do
    max_val =
      Enum.max_by(assigns.trend, fn {_, s} -> s.total end)
      |> elem(1)
      |> Map.get(:total)
      |> max(1)

    assigns = assign(assigns, :max_val, max_val)

    ~H"""
    <div class="px-6 py-4 border-b border-white/30">
      <div class="text-xs font-medium text-slate-500 mb-2">{@days}-day trend</div>
      <div class="h-16 flex items-end gap-px">
        <%= for {{date, stats}, idx} <- Enum.with_index(@trend) do %>
          <% height = if stats.total > 0, do: max(round(stats.total / @max_val * 100), 6), else: 0 %>
          <% bar_color = trend_bar_color(stats) %>
          <div class="flex-1 flex flex-col justify-end h-full group relative">
            <%= if stats.total > 0 do %>
              <div class={["rounded-t-sm", bar_color]} style={"height: #{height}%"} />
            <% else %>
              <div class="bg-slate-100 h-1 rounded-sm" />
            <% end %>
            <div class={[
              "hidden group-hover:block absolute bottom-full mb-2 px-2 py-1 bg-slate-800 text-white text-xs rounded whitespace-nowrap z-10",
              tooltip_position(idx, length(@trend))
            ]}>
              <div class="font-medium">{Calendar.strftime(date, "%b %d")}</div>
              <div>{stats.total} total</div>
              <%= if stats.failed > 0 do %>
                <div class="text-red-400">{stats.failed} failed</div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp trend_bar_color(%{total: 0}), do: "bg-slate-100"
  defp trend_bar_color(%{failed: 0}), do: "bg-emerald-500"
  defp trend_bar_color(%{failed: f, total: t}) when f > t / 2, do: "bg-red-400"
  defp trend_bar_color(_), do: "bg-amber-400"

  defp monitor_trend(%{trend: []} = assigns) do
    ~H""
  end

  defp monitor_trend(assigns) do
    total_monitors =
      Enum.max_by(assigns.trend, fn {_, s} -> s.total end)
      |> elem(1)
      |> Map.get(:total)
      |> max(1)

    assigns = assign(assigns, :total_monitors, total_monitors)

    ~H"""
    <div class="px-6 py-4 border-b border-white/30">
      <div class="text-xs font-medium text-slate-500 mb-2">{length(@trend)}-day uptime</div>
      <div class="h-16 flex items-end gap-px">
        <%= for {{date, stats}, idx} <- Enum.with_index(@trend) do %>
          <div class="flex-1 flex flex-col justify-end h-full group relative">
            <%= if stats.total > 0 do %>
              <div class="flex flex-col h-full">
                <%= if stats.down > 0 do %>
                  <div
                    class="bg-red-400 rounded-t-sm"
                    style={"height: #{round(stats.down / @total_monitors * 100)}%"}
                  />
                <% end %>
                <%= if stats.degraded > 0 do %>
                  <div
                    class={["bg-amber-400", if(stats.down == 0, do: "rounded-t-sm", else: "")]}
                    style={"height: #{round(stats.degraded / @total_monitors * 100)}%"}
                  />
                <% end %>
                <%= if stats.up > 0 do %>
                  <div
                    class={["bg-emerald-500 flex-1", if(stats.down == 0 && stats.degraded == 0, do: "rounded-t-sm", else: "")]}
                  />
                <% end %>
              </div>
            <% else %>
              <div class="bg-slate-100 h-1 rounded-sm" />
            <% end %>
            <div class={[
              "hidden group-hover:block absolute bottom-full mb-2 px-2 py-1 bg-slate-800 text-white text-xs rounded whitespace-nowrap z-10",
              tooltip_position(idx, length(@trend))
            ]}>
              <div class="font-medium">{Calendar.strftime(date, "%b %d")}</div>
              <%= if stats.up > 0 do %>
                <div class="text-emerald-400">{stats.up} up</div>
              <% end %>
              <%= if stats.degraded > 0 do %>
                <div class="text-amber-400">{stats.degraded} degraded</div>
              <% end %>
              <%= if stats.down > 0 do %>
                <div class="text-red-400">{stats.down} down</div>
              <% end %>
              <%= if stats.total == 0 do %>
                <div>No data</div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp tooltip_position(idx, total) do
    cond do
      idx < 3 -> "left-0"
      idx > total - 4 -> "right-0"
      true -> "left-1/2 -translate-x-1/2"
    end
  end

  defp job_summary(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <span class="text-slate-500">{@stats.active_jobs} active</span>
      <%= if @stats.today_failed > 0 do %>
        <span class="text-red-600 font-medium">{@stats.today_failed} failed today</span>
      <% end %>
    </div>
    """
  end

  defp monitor_summary(assigns) do
    up = Enum.count(assigns.monitors, &(&1.status == "up"))
    down = Enum.count(assigns.monitors, &(&1.status == "down"))
    other = length(assigns.monitors) - up - down
    assigns = assign(assigns, %{up: up, down: down, other: other})

    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <%= if @up > 0 do %>
        <span class="text-emerald-600 font-medium">{@up} up</span>
      <% end %>
      <%= if @down > 0 do %>
        <span class="text-red-600 font-medium">{@down} down</span>
      <% end %>
      <%= if @other > 0 do %>
        <span class="text-slate-400">{@other} other</span>
      <% end %>
    </div>
    """
  end

  defp monitor_dot_color("up"), do: "bg-emerald-500"
  defp monitor_dot_color("down"), do: "bg-red-500"
  defp monitor_dot_color("new"), do: "bg-slate-400"
  defp monitor_dot_color("paused"), do: "bg-amber-400"
  defp monitor_dot_color(_), do: "bg-slate-300"

  defp monitor_status_label("up"), do: "Up"
  defp monitor_status_label("down"), do: "Down"
  defp monitor_status_label("new"), do: "Awaiting ping"
  defp monitor_status_label("paused"), do: "Paused"
  defp monitor_status_label(_), do: "Unknown"

  defp status_dot_color(nil), do: "bg-slate-300"
  defp status_dot_color("success"), do: "bg-emerald-600"
  defp status_dot_color("failed"), do: "bg-red-500"
  defp status_dot_color("timeout"), do: "bg-amber-500"
  defp status_dot_color("running"), do: "bg-blue-500 animate-pulse"
  defp status_dot_color("pending"), do: "bg-slate-400"
  defp status_dot_color("missed"), do: "bg-orange-500"
  defp status_dot_color(_), do: "bg-slate-300"

  defp status_dot_title(nil), do: "No executions yet"
  defp status_dot_title("success"), do: "Last run: Success"
  defp status_dot_title("failed"), do: "Last run: Failed"
  defp status_dot_title("timeout"), do: "Last run: Timeout"
  defp status_dot_title("running"), do: "Currently running"
  defp status_dot_title("pending"), do: "Pending execution"
  defp status_dot_title("missed"), do: "Last run: Missed"
  defp status_dot_title(_), do: "Unknown status"

end
