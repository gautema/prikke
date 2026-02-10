defmodule PrikkeWeb.SuperadminLive do
  use PrikkeWeb, :live_view

  alias Prikke.Accounts
  alias Prikke.Tasks
  alias Prikke.Executions
  alias Prikke.Monitors
  alias Prikke.Endpoints
  alias Prikke.Analytics
  alias Prikke.Audit
  alias Prikke.Emails

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Auto-refresh every 30 seconds
      :timer.send_interval(30_000, :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Superadmin Dashboard")
      |> load_stats()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_stats(socket)}
  end

  defp load_stats(socket) do
    now = DateTime.utc_now()
    seven_days_ago = DateTime.add(now, -7, :day)
    thirty_days_ago = DateTime.add(now, -30, :day)

    # Platform stats
    platform_stats = %{
      total_users: Accounts.count_users(),
      users_this_week: Accounts.count_users_since(seven_days_ago),
      users_this_month: Accounts.count_users_since(thirty_days_ago),
      total_orgs: Accounts.count_organizations(),
      total_tasks: Tasks.count_all_tasks(),
      enabled_tasks: Tasks.count_all_enabled_tasks()
    }

    # Execution stats
    exec_stats = Executions.get_platform_stats()
    success_rate = Executions.get_platform_success_rate(seven_days_ago)

    # Analytics (pageviews)
    analytics = Analytics.get_pageview_stats()

    # Recent activity
    recent_users = Accounts.list_recent_users(limit: 5)
    recent_tasks = Tasks.list_recent_tasks_all(limit: 5)
    active_orgs = Accounts.list_active_organizations(limit: 5)
    recent_executions = Executions.list_recent_executions_all(limit: 10)

    # Pro count for stats
    pro_count = Accounts.count_pro_organizations()

    # Execution trend
    execution_trend = Executions.executions_by_day(14)

    # Monthly executions per org
    org_monthly_executions = Executions.list_organization_monthly_executions(limit: 20)

    # Monitor stats
    monitor_stats = %{
      total: Monitors.count_all_monitors(),
      down: Monitors.count_all_down_monitors()
    }

    # Endpoint stats
    endpoint_stats = %{
      total: Endpoints.count_all_endpoints(),
      enabled: Endpoints.count_all_enabled_endpoints(),
      total_events: Endpoints.count_all_inbound_events(),
      events_this_week: Endpoints.count_inbound_events_since(seven_days_ago),
      events_this_month: Endpoints.count_inbound_events_since(thirty_days_ago)
    }

    recent_endpoints = Endpoints.list_recent_endpoints_all(limit: 5)

    # Recent audit logs
    audit_logs = Audit.list_all_logs(limit: 20)

    # Email logs
    recent_emails = Emails.list_recent_emails(limit: 20)
    emails_this_month = Emails.count_emails_this_month()
    monthly_summary_emails = Emails.list_monthly_summary_emails(limit: 12)

    # System performance metrics
    metrics = Prikke.Metrics.current()
    metrics_history = Prikke.Metrics.recent(60)
    duration_percentiles = Executions.get_duration_percentiles()
    queue_wait = Executions.get_avg_queue_wait()
    throughput = Executions.throughput_per_minute(60)
    system_alerts = Prikke.Metrics.alerts()

    socket
    |> assign(:metrics, metrics)
    |> assign(:metrics_history, metrics_history)
    |> assign(:duration_percentiles, duration_percentiles)
    |> assign(:queue_wait, queue_wait)
    |> assign(:throughput, throughput)
    |> assign(:system_alerts, system_alerts)
    |> assign(:platform_stats, platform_stats)
    |> assign(:org_monthly_executions, org_monthly_executions)
    |> assign(:exec_stats, exec_stats)
    |> assign(:success_rate, success_rate)
    |> assign(:analytics, analytics)
    |> assign(:recent_users, recent_users)
    |> assign(:recent_tasks, recent_tasks)
    |> assign(:active_orgs, active_orgs)
    |> assign(:recent_executions, recent_executions)
    |> assign(:pro_count, pro_count)
    |> assign(:execution_trend, execution_trend)
    |> assign(:monitor_stats, monitor_stats)
    |> assign(:endpoint_stats, endpoint_stats)
    |> assign(:recent_endpoints, recent_endpoints)
    |> assign(:audit_logs, audit_logs)
    |> assign(:recent_emails, recent_emails)
    |> assign(:emails_this_month, emails_this_month)
    |> assign(:monthly_summary_emails, monthly_summary_emails)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto py-8 px-4">
      <div class="mb-8 flex justify-between items-start">
        <div>
          <h1 class="text-2xl font-bold text-slate-900">Superadmin Dashboard</h1>
          <p class="text-slate-500 mt-1">Platform-wide analytics and monitoring</p>
        </div>
        <div class="flex gap-2">
          <a
            href="/live-dashboard"
            class="px-4 py-2 text-sm font-medium text-slate-700 bg-white border border-slate-300 hover:bg-white/50 rounded-md transition-colors"
          >
            Live Dashboard
          </a>
          <a
            href="/errors"
            class="px-4 py-2 text-sm font-medium text-white bg-red-600 hover:bg-red-700 rounded-md transition-colors"
          >
            View Errors
          </a>
        </div>
      </div>
      
    <!-- Platform Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        <.stat_card
          title="Total Users"
          value={@platform_stats.total_users}
          subtitle={"#{@platform_stats.users_this_week} this week"}
        />
        <.stat_card
          title="Organizations"
          value={@platform_stats.total_orgs}
          subtitle={"#{@pro_count} Pro"}
        />
        <.stat_card
          title="Total Tasks"
          value={@platform_stats.total_tasks}
          subtitle={"#{@platform_stats.enabled_tasks} enabled"}
        />
        <.stat_card
          title="Endpoints"
          value={@endpoint_stats.total}
          subtitle={"#{@endpoint_stats.enabled} enabled"}
        />
        <.stat_card
          title="Monitors"
          value={@monitor_stats.total}
          subtitle={"#{@monitor_stats.down} down"}
          color={if @monitor_stats.down > 0, do: "text-red-600", else: "text-slate-900"}
        />
        <.stat_card
          title="Success Rate (7d)"
          value={if @success_rate, do: "#{@success_rate}%", else: "—"}
          color={success_rate_color(@success_rate)}
        />
        <.stat_card title="Pro Customers" value={@pro_count} color="text-emerald-600" />
        <.stat_card title="Emails This Month" value={@emails_this_month} />
      </div>
      
    <!-- Execution Stats -->
      <div class="glass-card rounded-2xl p-6 mb-8">
        <h2 class="text-lg font-semibold text-slate-900 mb-4">Execution Stats</h2>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-6">
          <div>
            <div class="text-sm text-slate-500 mb-1">Today</div>
            <div class="text-2xl font-bold text-slate-900">{@exec_stats.today.total}</div>
            <div class="text-xs text-slate-500 mt-1">
              <span class="text-emerald-600">{@exec_stats.today.success} ok</span>
              <span class="mx-1">·</span>
              <span class="text-red-600">{@exec_stats.today.failed} fail</span>
              <%= if @exec_stats.today.missed > 0 do %>
                <span class="mx-1">·</span>
                <span class="text-orange-600">{@exec_stats.today.missed} missed</span>
              <% end %>
            </div>
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">Last 7 Days</div>
            <div class="text-2xl font-bold text-slate-900">{@exec_stats.seven_days.total}</div>
            <div class="text-xs text-slate-500 mt-1">
              <span class="text-emerald-600">{@exec_stats.seven_days.success} ok</span>
              <span class="mx-1">·</span>
              <span class="text-red-600">{@exec_stats.seven_days.failed} fail</span>
              <%= if @exec_stats.seven_days.missed > 0 do %>
                <span class="mx-1">·</span>
                <span class="text-orange-600">{@exec_stats.seven_days.missed} missed</span>
              <% end %>
            </div>
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">Last 30 Days</div>
            <div class="text-2xl font-bold text-slate-900">{@exec_stats.thirty_days.total}</div>
            <div class="text-xs text-slate-500 mt-1">
              <span class="text-emerald-600">{@exec_stats.thirty_days.success} ok</span>
              <span class="mx-1">·</span>
              <span class="text-red-600">{@exec_stats.thirty_days.failed} fail</span>
              <%= if @exec_stats.thirty_days.missed > 0 do %>
                <span class="mx-1">·</span>
                <span class="text-orange-600">{@exec_stats.thirty_days.missed} missed</span>
              <% end %>
            </div>
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">This Month</div>
            <div class="text-2xl font-bold text-slate-900">{@exec_stats.this_month.total}</div>
            <div class="text-xs text-slate-500 mt-1">
              <span class="text-emerald-600">{@exec_stats.this_month.success} ok</span>
              <span class="mx-1">·</span>
              <span class="text-red-600">{@exec_stats.this_month.failed} fail</span>
              <%= if @exec_stats.this_month.missed > 0 do %>
                <span class="mx-1">·</span>
                <span class="text-orange-600">{@exec_stats.this_month.missed} missed</span>
              <% end %>
            </div>
          </div>
        </div>
      </div>
      
    <!-- System Performance -->
      <div class="glass-card rounded-2xl p-6 mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-lg font-semibold text-slate-900">System Performance</h2>
          <span class="text-xs text-slate-400">Updated every 10s</span>
        </div>
        
    <!-- Real-time metrics -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <div>
            <div class="text-sm text-slate-500 mb-1">Queue Depth</div>
            <div class={[
              "text-2xl font-bold",
              cond do
                Map.get(@metrics, :queue_depth, 0) >= 200 -> "text-red-600"
                Map.get(@metrics, :queue_depth, 0) >= 50 -> "text-amber-600"
                true -> "text-slate-900"
              end
            ]}>
              {Map.get(@metrics, :queue_depth, 0)}
            </div>
            <.sparkline data={Enum.map(@metrics_history, &Map.get(&1, :queue_depth, 0))} />
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">Active Workers</div>
            <div class="text-2xl font-bold text-slate-900">
              {Map.get(@metrics, :active_workers, 0)}
            </div>
            <.sparkline data={Enum.map(@metrics_history, &Map.get(&1, :active_workers, 0))} />
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">CPU Usage</div>
            <div class={[
              "text-2xl font-bold",
              cond do
                Map.get(@metrics, :cpu_percent, 0) >= 95 -> "text-red-600"
                Map.get(@metrics, :cpu_percent, 0) >= 80 -> "text-amber-600"
                true -> "text-slate-900"
              end
            ]}>
              {Map.get(@metrics, :cpu_percent, 0)}%
            </div>
            <.sparkline data={Enum.map(@metrics_history, &Map.get(&1, :cpu_percent, 0))} color="blue" />
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">Memory Usage</div>
            <div class={[
              "text-2xl font-bold",
              cond do
                Map.get(@metrics, :system_memory_used_pct, 0) >= 90 -> "text-red-600"
                Map.get(@metrics, :system_memory_used_pct, 0) >= 80 -> "text-amber-600"
                true -> "text-slate-900"
              end
            ]}>
              {Map.get(@metrics, :system_memory_used_pct, 0)}%
            </div>
            <div class="text-xs text-slate-400 mt-0.5">
              {Float.round(Map.get(@metrics, :system_memory_used_mb, 0) / 1024, 1)} / {Float.round(
                Map.get(@metrics, :system_memory_total_mb, 0) / 1024,
                1
              )} GB
            </div>
          </div>
        </div>
        
    <!-- Response time percentiles -->
        <div class="border-t border-white/50 pt-4 mb-4">
          <div class="text-sm font-medium text-slate-700 mb-3">
            Webhook Response Times (last 1 hour)
          </div>
          <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
            <div>
              <div class="text-xs text-slate-500">p50</div>
              <div class="text-lg font-bold text-slate-900">
                {format_duration_short(@duration_percentiles && @duration_percentiles.p50)}
              </div>
            </div>
            <div>
              <div class="text-xs text-slate-500">p95</div>
              <div class="text-lg font-bold text-slate-900">
                {format_duration_short(@duration_percentiles && @duration_percentiles.p95)}
              </div>
            </div>
            <div>
              <div class="text-xs text-slate-500">p99</div>
              <div class="text-lg font-bold text-slate-900">
                {format_duration_short(@duration_percentiles && @duration_percentiles.p99)}
              </div>
            </div>
            <div>
              <div class="text-xs text-slate-500">Avg</div>
              <div class="text-lg font-bold text-slate-900">
                {format_duration_short(@duration_percentiles && @duration_percentiles.avg)}
              </div>
            </div>
            <div>
              <div class="text-xs text-slate-500">Count</div>
              <div class="text-lg font-bold text-slate-900">
                {(@duration_percentiles && @duration_percentiles.count) || 0}
              </div>
            </div>
          </div>
        </div>
        
    <!-- Secondary metrics -->
        <div class="border-t border-white/50 pt-4 grid grid-cols-2 md:grid-cols-5 gap-4">
          <div>
            <div class="text-xs text-slate-500">Queue Wait (avg)</div>
            <div class="text-base font-semibold text-slate-900">
              {format_duration_short(@queue_wait && @queue_wait.avg_wait_ms)}
            </div>
          </div>
          <div>
            <div class="text-xs text-slate-500">Throughput</div>
            <div class="text-base font-semibold text-slate-900">
              {throughput_per_min(@throughput)}/min
            </div>
          </div>
          <div>
            <div class="text-xs text-slate-500">Disk Usage</div>
            <div class={[
              "text-base font-semibold",
              cond do
                Map.get(@metrics, :disk_usage_pct, 0) >= 90 -> "text-red-600"
                Map.get(@metrics, :disk_usage_pct, 0) >= 80 -> "text-amber-600"
                true -> "text-slate-900"
              end
            ]}>
              {Map.get(@metrics, :disk_usage_pct, 0)}%
            </div>
          </div>
          <div>
            <div class="text-xs text-slate-500">BEAM Processes</div>
            <div class="text-base font-semibold text-slate-900">
              {format_number(Map.get(@metrics, :beam_processes, 0))}
            </div>
          </div>
          <div>
            <div class="text-xs text-slate-500">BEAM Memory</div>
            <div class="text-base font-semibold text-slate-900">
              {Map.get(@metrics, :beam_memory_mb, 0)} MB
            </div>
          </div>
        </div>
        
    <!-- Alerts -->
        <%= if @system_alerts != [] do %>
          <div class="border-t border-white/50 pt-4 mt-4">
            <div class="text-sm font-medium text-slate-700 mb-2">Active Alerts</div>
            <div class="space-y-2">
              <%= for alert <- @system_alerts do %>
                <div class={[
                  "flex items-center gap-2 px-3 py-2 rounded-lg text-sm",
                  if(alert.level == :critical,
                    do: "bg-red-50 text-red-800",
                    else: "bg-amber-50 text-amber-800"
                  )
                ]}>
                  <span class="font-medium">
                    {if alert.level == :critical, do: "CRITICAL", else: "WARNING"}
                  </span>
                  <span>
                    {alert.metric}: {alert.value}
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
      
    <!-- Execution Trend Chart -->
      <div class="glass-card rounded-2xl p-6 mb-8">
        <h2 class="text-lg font-semibold text-slate-900 mb-4">Execution Trend (14 days)</h2>
        <%= if @execution_trend == [] do %>
          <div class="h-32 flex items-center justify-center text-slate-400">
            No executions in the last 14 days
          </div>
        <% else %>
          <div class="h-32 flex items-end gap-1">
            <% max_val =
              Enum.max_by(@execution_trend, fn {_, s} -> s.total end)
              |> elem(1)
              |> Map.get(:total)
              |> max(1) %>
            <%= for {{date, stats}, idx} <- Enum.with_index(@execution_trend) do %>
              <% height = if stats.total > 0, do: max(round(stats.total / max_val * 100), 4), else: 0 %>
              <% success_pct =
                if stats.total > 0, do: round(stats.success / stats.total * 100), else: 0 %>
              <% failed_pct = 100 - success_pct %>
              <div class="flex-1 flex flex-col justify-end h-full group relative">
                <div class="flex flex-col" style={"height: #{height}%"}>
                  <%= if failed_pct > 0 && stats.failed > 0 do %>
                    <div class="bg-red-400 rounded-t-sm flex-none" style={"height: #{failed_pct}%"}>
                    </div>
                  <% end %>
                  <%= if success_pct > 0 && stats.success > 0 do %>
                    <div class={[
                      "bg-emerald-600 flex-1",
                      if(stats.failed == 0, do: "rounded-t-sm", else: "")
                    ]}>
                    </div>
                  <% end %>
                  <%= if stats.total == 0 do %>
                    <div class="bg-slate-100 h-1 rounded-sm"></div>
                  <% end %>
                </div>
                <!-- Tooltip -->
                <div class={[
                  "hidden group-hover:block absolute bottom-full mb-2 px-2 py-1 bg-slate-800 text-white text-xs rounded whitespace-nowrap z-10",
                  if(idx < 3,
                    do: "left-0",
                    else: if(idx > 10, do: "right-0", else: "left-1/2 -translate-x-1/2")
                  )
                ]}>
                  <div class="font-medium">{Calendar.strftime(date, "%b %d")}</div>
                  <div>{stats.total} total</div>
                  <%= if stats.success > 0 do %>
                    <div class="text-emerald-400">{stats.success} success</div>
                  <% end %>
                  <%= if stats.failed > 0 do %>
                    <div class="text-red-400">{stats.failed} failed</div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
          <div class="flex justify-between mt-2 text-xs text-slate-400">
            <span>14 days ago</span>
            <span>Today</span>
          </div>
        <% end %>
      </div>
      
    <!-- Analytics Section -->
      <div class="grid md:grid-cols-2 gap-8 mb-8">
        <!-- Pageviews -->
        <div class="glass-card rounded-2xl p-6">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Pageviews</h2>
          <div class="grid grid-cols-3 gap-4 mb-6">
            <div>
              <div class="text-sm text-slate-500">Today</div>
              <div class="text-xl font-bold text-slate-900">{@analytics.today}</div>
              <div class="text-xs text-slate-400">{@analytics.today_unique} unique</div>
            </div>
            <div>
              <div class="text-sm text-slate-500">7 Days</div>
              <div class="text-xl font-bold text-slate-900">{@analytics.seven_days}</div>
              <div class="text-xs text-slate-400">{@analytics.seven_days_unique} unique</div>
            </div>
            <div>
              <div class="text-sm text-slate-500">30 Days</div>
              <div class="text-xl font-bold text-slate-900">{@analytics.thirty_days}</div>
              <div class="text-xs text-slate-400">{@analytics.thirty_days_unique} unique</div>
            </div>
          </div>
          <h3 class="text-sm font-medium text-slate-700 mb-2">Top Pages (7d)</h3>
          <div class="space-y-1">
            <%= for {path, count} <- @analytics.top_pages do %>
              <div class="flex justify-between text-sm">
                <span class="text-slate-600 truncate mr-2 font-mono">{path}</span>
                <span class="text-slate-500 shrink-0">{count}</span>
              </div>
            <% end %>
            <%= if @analytics.top_pages == [] do %>
              <div class="text-sm text-slate-400">No pageviews yet</div>
            <% end %>
          </div>
        </div>
        
    <!-- Active Organizations -->
        <div class="glass-card rounded-2xl p-6">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Most Active Organizations</h2>
          <div class="space-y-3">
            <%= for {org, exec_count} <- @active_orgs do %>
              <div class="flex justify-between items-center">
                <div>
                  <div class="font-medium text-slate-900">{org.name}</div>
                  <div class="text-xs text-slate-500">{org.tier}</div>
                </div>
                <div class="text-sm text-slate-600">{exec_count} executions</div>
              </div>
            <% end %>
            <%= if @active_orgs == [] do %>
              <div class="text-sm text-slate-400">No activity yet</div>
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Monthly Executions by Organization -->
      <div class="glass-card rounded-2xl p-6 mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-lg font-semibold text-slate-900">Monthly Executions by Organization</h2>
          <span class="text-sm text-slate-500">{Calendar.strftime(DateTime.utc_now(), "%B %Y")}</span>
        </div>
        <div class="overflow-x-auto">
          <table class="min-w-full">
            <thead>
              <tr class="border-b border-white/50">
                <th class="py-2 text-left text-sm font-medium text-slate-500">Organization</th>
                <th class="py-2 text-left text-sm font-medium text-slate-500">Tier</th>
                <th class="py-2 text-right text-sm font-medium text-slate-500">Executions</th>
                <th class="py-2 text-right text-sm font-medium text-slate-500">Limit</th>
                <th class="py-2 text-right text-sm font-medium text-slate-500">Usage</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-white/30">
              <%= for {org, count, limit} <- @org_monthly_executions do %>
                <% usage_pct = Float.round(count / limit * 100, 1) %>
                <tr>
                  <td class="py-2 font-medium text-slate-900">{org.name}</td>
                  <td class="py-2">
                    <span class={[
                      "text-xs px-2 py-0.5 rounded-full",
                      if(org.tier == "pro",
                        do: "bg-emerald-100 text-emerald-700",
                        else: "bg-slate-100 text-slate-600"
                      )
                    ]}>
                      {org.tier}
                    </span>
                  </td>
                  <td class="py-2 text-right font-mono text-sm text-slate-600">
                    {format_number(count)}
                  </td>
                  <td class="py-2 text-right font-mono text-sm text-slate-400">
                    {format_number(limit)}
                  </td>
                  <td class="py-2 text-right">
                    <span class={[
                      "text-sm font-medium",
                      cond do
                        usage_pct >= 100 -> "text-red-600"
                        usage_pct >= 80 -> "text-amber-600"
                        true -> "text-slate-600"
                      end
                    ]}>
                      {usage_pct}%
                    </span>
                  </td>
                </tr>
              <% end %>
              <%= if @org_monthly_executions == [] do %>
                <tr>
                  <td colspan="5" class="py-8 text-center text-slate-400">
                    No executions this month
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
      
    <!-- Recent Activity -->
      <div class="grid md:grid-cols-2 gap-8 mb-8">
        <!-- Recent Signups -->
        <div class="glass-card rounded-2xl p-6 hover:z-10">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Recent Signups</h2>
          <div class="space-y-3">
            <%= for user <- @recent_users do %>
              <div class="flex justify-between items-center gap-2">
                <span class="text-slate-900 truncate min-w-0">{user.email}</span>
                <span class="text-xs text-slate-400 whitespace-nowrap">
                  <.relative_time id={"user-#{user.id}"} datetime={user.inserted_at} />
                </span>
              </div>
            <% end %>
            <%= if @recent_users == [] do %>
              <div class="text-sm text-slate-400">No users yet</div>
            <% end %>
          </div>
        </div>
        
    <!-- Recent Tasks -->
        <div class="glass-card rounded-2xl p-6 hover:z-10">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Recent Tasks</h2>
          <div class="space-y-3">
            <%= for task <- @recent_tasks do %>
              <div class="flex justify-between items-center gap-2">
                <div class="min-w-0 flex-1">
                  <div class="font-medium text-slate-900 truncate">{task.name}</div>
                  <div class="text-xs text-slate-500 truncate">
                    {task.organization && task.organization.name}
                  </div>
                </div>
                <span class="text-xs text-slate-400 whitespace-nowrap">
                  <.relative_time id={"task-#{task.id}"} datetime={task.inserted_at} />
                </span>
              </div>
            <% end %>
            <%= if @recent_tasks == [] do %>
              <div class="text-sm text-slate-400">No tasks yet</div>
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Endpoint Stats -->
      <div class="glass-card rounded-2xl p-6 mb-8">
        <h2 class="text-lg font-semibold text-slate-900 mb-4">Inbound Endpoints</h2>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-6 mb-6">
          <div>
            <div class="text-sm text-slate-500 mb-1">Total Endpoints</div>
            <div class="text-2xl font-bold text-slate-900">{@endpoint_stats.total}</div>
            <div class="text-xs text-slate-500 mt-1">
              <span class="text-emerald-600">{@endpoint_stats.enabled} enabled</span>
              <span class="mx-1">&middot;</span>
              <span class="text-slate-400">{@endpoint_stats.total - @endpoint_stats.enabled} disabled</span>
            </div>
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">Total Events</div>
            <div class="text-2xl font-bold text-slate-900">{@endpoint_stats.total_events}</div>
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">Events (7d)</div>
            <div class="text-2xl font-bold text-slate-900">{@endpoint_stats.events_this_week}</div>
          </div>
          <div>
            <div class="text-sm text-slate-500 mb-1">Events (30d)</div>
            <div class="text-2xl font-bold text-slate-900">{@endpoint_stats.events_this_month}</div>
          </div>
        </div>
        <div class="border-t border-white/50 pt-4">
          <h3 class="text-sm font-medium text-slate-700 mb-3">Recent Endpoints</h3>
          <div class="space-y-3">
            <%= for endpoint <- @recent_endpoints do %>
              <div class="flex items-center justify-between gap-2">
                <div class="flex items-center gap-2 min-w-0">
                  <span class={[
                    "w-2 h-2 rounded-full shrink-0",
                    if(endpoint.enabled, do: "bg-emerald-500", else: "bg-slate-400")
                  ]} />
                  <span class="text-sm font-medium text-slate-900 truncate">{endpoint.name}</span>
                  <span class="text-xs text-slate-400 font-mono">/in/{endpoint.slug}</span>
                </div>
                <div class="flex items-center gap-3 shrink-0">
                  <span class="text-xs text-slate-400">{endpoint.organization && endpoint.organization.name}</span>
                  <span class="text-xs text-slate-400">
                    <.relative_time id={"ep-#{endpoint.id}"} datetime={endpoint.inserted_at} />
                  </span>
                </div>
              </div>
            <% end %>
            <%= if @recent_endpoints == [] do %>
              <div class="text-sm text-slate-400">No endpoints yet</div>
            <% end %>
          </div>
        </div>
      </div>

    <!-- Recent Executions & Audit Logs -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
        <!-- Recent Executions -->
        <div class="glass-card rounded-2xl hover:z-10">
          <div class="px-6 py-4 border-b border-white/50">
            <h2 class="text-lg font-semibold text-slate-900">Recent Executions</h2>
          </div>
          <div class="divide-y divide-white/30">
            <%= for execution <- @recent_executions do %>
              <div class="px-6 py-3 flex items-center gap-4">
                <.status_dot status={execution.status} />
                <%= if execution.status_code do %>
                  <span class="text-sm font-mono text-slate-500">{execution.status_code}</span>
                <% end %>
                <%= if execution.duration_ms do %>
                  <span class="text-sm text-slate-500">{format_duration(execution.duration_ms)}</span>
                <% end %>
                <span class="text-sm text-slate-400">
                  <.relative_time id={"exec-#{execution.id}"} datetime={execution.scheduled_for} />
                </span>
              </div>
            <% end %>
            <%= if @recent_executions == [] do %>
              <div class="px-6 py-8 text-center text-slate-400">No executions yet</div>
            <% end %>
          </div>
        </div>
        
    <!-- Audit Logs -->
        <div class="glass-card rounded-2xl hover:z-10">
          <div class="px-6 py-4 border-b border-white/50">
            <h2 class="text-lg font-semibold text-slate-900">Recent Audit Logs</h2>
          </div>
          <div class="divide-y divide-white/30">
            <%= for log <- @audit_logs do %>
              <div class="px-6 py-3">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <span class={[
                      "text-xs px-2 py-0.5 rounded-full font-medium",
                      action_badge_class(log.action)
                    ]}>
                      {Audit.format_action(log.action)}
                    </span>
                    <span class="text-sm text-slate-600">
                      {Audit.format_resource_type(log.resource_type)}
                    </span>
                  </div>
                  <span class="text-xs text-slate-400">
                    <.relative_time id={"audit-#{log.id}"} datetime={log.inserted_at} />
                  </span>
                </div>
                <div class="mt-1 text-sm text-slate-500">
                  <%= case log.actor_type do %>
                    <% "user" -> %>
                      <span class="text-slate-700">{log.actor && log.actor.email}</span>
                    <% "api" -> %>
                      <span class="text-amber-600">API: {log.metadata["api_key_name"]}</span>
                    <% "system" -> %>
                      <span class="text-slate-400">System</span>
                    <% _ -> %>
                      <span class="text-slate-400">Unknown</span>
                  <% end %>
                  <%= if log.organization do %>
                    <span class="mx-1">·</span>
                    <span class="text-slate-400">{log.organization.name}</span>
                  <% end %>
                </div>
                <%= if log.changes != %{} do %>
                  <div class="mt-1 text-xs text-slate-400 font-mono truncate">
                    {inspect(log.changes, limit: 3)}
                  </div>
                <% end %>
              </div>
            <% end %>
            <%= if @audit_logs == [] do %>
              <div class="px-6 py-8 text-center text-slate-400">No audit logs yet</div>
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Monthly Summary Emails -->
      <div class="glass-card rounded-2xl mb-8">
        <div class="px-6 py-4 border-b border-white/50 flex justify-between items-center">
          <h2 class="text-lg font-semibold text-slate-900">Monthly Summary Emails</h2>
          <span class="text-xs text-slate-400">Sent on the 1st of each month</span>
        </div>
        <div class="divide-y divide-white/30">
          <%= for email <- @monthly_summary_emails do %>
            <div class="px-6 py-3 flex items-center gap-4">
              <span class={[
                "w-2 h-2 rounded-full shrink-0",
                if(email.status == "sent", do: "bg-emerald-600", else: "bg-red-500")
              ]} />
              <span class="text-sm font-medium text-slate-900">{email.subject}</span>
              <span class={[
                "text-xs px-2 py-0.5 rounded-full font-medium shrink-0",
                if(email.status == "sent",
                  do: "bg-emerald-100 text-emerald-700",
                  else: "bg-red-100 text-red-700"
                )
              ]}>
                {email.status}
              </span>
              <span class="text-xs text-slate-400 whitespace-nowrap shrink-0 ml-auto">
                <.relative_time id={"monthly-email-#{email.id}"} datetime={email.inserted_at} />
              </span>
            </div>
          <% end %>
          <%= if @monthly_summary_emails == [] do %>
            <div class="px-6 py-8 text-center text-slate-400">
              No monthly summaries sent yet. First one will be sent on the 1st of next month.
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Recent Emails -->
      <div class="glass-card rounded-2xl mb-8">
        <div class="px-6 py-4 border-b border-white/50">
          <h2 class="text-lg font-semibold text-slate-900">Recent Emails</h2>
        </div>
        <div class="divide-y divide-white/30">
          <%= for email <- @recent_emails do %>
            <div class="px-6 py-3 flex items-center gap-4">
              <span class={[
                "w-2 h-2 rounded-full shrink-0",
                if(email.status == "sent", do: "bg-emerald-600", else: "bg-red-500")
              ]} />
              <span class="text-sm text-slate-900 truncate min-w-0 max-w-[200px]">{email.to}</span>
              <span class="text-sm text-slate-600 truncate min-w-0 flex-1">{email.subject}</span>
              <span class={[
                "text-xs px-2 py-0.5 rounded-full font-medium shrink-0",
                email_type_badge_class(email.email_type)
              ]}>
                {email.email_type}
              </span>
              <%= if email.organization do %>
                <span class="text-xs text-slate-400 shrink-0">{email.organization.name}</span>
              <% end %>
              <span class="text-xs text-slate-400 whitespace-nowrap shrink-0">
                <.relative_time id={"email-#{email.id}"} datetime={email.inserted_at} />
              </span>
            </div>
          <% end %>
          <%= if @recent_emails == [] do %>
            <div class="px-6 py-8 text-center text-slate-400">No emails sent yet</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp sparkline(assigns) do
    assigns = assign_new(assigns, :color, fn -> "emerald" end)
    data = assigns.data

    max_val = if data == [], do: 1, else: max(Enum.max(data), 1)

    assigns = assign(assigns, :max_val, max_val)

    ~H"""
    <div class="flex items-end gap-px h-8 mt-1">
      <%= for {val, _idx} <- Enum.with_index(@data) do %>
        <% height = if val > 0, do: max(round(val / @max_val * 100), 8), else: 0 %>
        <div
          class={[
            "flex-1 rounded-t-sm min-w-[2px]",
            cond do
              @color == "blue" -> "bg-blue-400/60"
              true -> "bg-emerald-400/60"
            end
          ]}
          style={"height: #{height}%"}
        />
      <% end %>
      <%= if @data == [] do %>
        <div class="flex-1 text-xs text-slate-300 text-center">No data</div>
      <% end %>
    </div>
    """
  end

  defp stat_card(assigns) do
    assigns = assign_new(assigns, :subtitle, fn -> nil end)
    assigns = assign_new(assigns, :color, fn -> "text-slate-900" end)

    ~H"""
    <div class="glass-card rounded-2xl p-4">
      <div class="text-sm font-medium text-slate-500 mb-1">{@title}</div>
      <div class={["text-2xl font-bold", @color]}>{@value}</div>
      <%= if @subtitle do %>
        <div class="text-xs text-slate-400 mt-1">{@subtitle}</div>
      <% end %>
    </div>
    """
  end

  defp status_dot(assigns) do
    ~H"""
    <span class={["w-2 h-2 rounded-full shrink-0", status_dot_color(@status)]} />
    """
  end

  defp status_dot_color("success"), do: "bg-emerald-600"
  defp status_dot_color("failed"), do: "bg-red-500"
  defp status_dot_color("timeout"), do: "bg-amber-500"
  defp status_dot_color("running"), do: "bg-blue-500 animate-pulse"
  defp status_dot_color("pending"), do: "bg-slate-400"
  defp status_dot_color("missed"), do: "bg-orange-500"
  defp status_dot_color(_), do: "bg-slate-300"

  defp success_rate_color(nil), do: "text-slate-900"
  defp success_rate_color(rate) when rate >= 95, do: "text-emerald-600"
  defp success_rate_color(rate) when rate >= 80, do: "text-amber-600"
  defp success_rate_color(_), do: "text-red-600"

  defp format_duration(nil), do: nil
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(num), do: to_string(num)

  defp email_type_badge_class("job_failure"), do: "bg-red-100 text-red-700"
  defp email_type_badge_class("job_recovery"), do: "bg-emerald-100 text-emerald-700"
  defp email_type_badge_class("monitor_down"), do: "bg-red-100 text-red-700"
  defp email_type_badge_class("monitor_recovery"), do: "bg-emerald-100 text-emerald-700"
  defp email_type_badge_class("login_instructions"), do: "bg-blue-100 text-blue-700"
  defp email_type_badge_class("confirmation"), do: "bg-blue-100 text-blue-700"
  defp email_type_badge_class("organization_invite"), do: "bg-purple-100 text-purple-700"
  defp email_type_badge_class("limit_warning"), do: "bg-amber-100 text-amber-700"
  defp email_type_badge_class("limit_reached"), do: "bg-red-100 text-red-700"
  defp email_type_badge_class("monthly_summary"), do: "bg-indigo-100 text-indigo-700"
  defp email_type_badge_class(_), do: "bg-slate-100 text-slate-600"

  defp format_duration_short(nil), do: "-"

  defp format_duration_short(%Decimal{} = ms) do
    format_duration_short(Decimal.to_float(ms))
  end

  defp format_duration_short(ms) when is_float(ms), do: format_duration_short(round(ms))
  defp format_duration_short(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration_short(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration_short(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp throughput_per_min([]), do: "0"

  defp throughput_per_min(throughput) do
    total = Enum.reduce(throughput, 0, fn {_ts, count}, acc -> acc + count end)
    minutes = max(length(throughput), 1)
    Float.round(total / minutes, 1) |> to_string()
  end

  defp action_badge_class("created"), do: "bg-emerald-100 text-emerald-700"
  defp action_badge_class("updated"), do: "bg-blue-100 text-blue-700"
  defp action_badge_class("deleted"), do: "bg-red-100 text-red-700"
  defp action_badge_class("enabled"), do: "bg-emerald-100 text-emerald-700"
  defp action_badge_class("disabled"), do: "bg-slate-100 text-slate-600"
  defp action_badge_class("triggered"), do: "bg-amber-100 text-amber-700"
  defp action_badge_class("upgraded"), do: "bg-purple-100 text-purple-700"
  defp action_badge_class("downgraded"), do: "bg-slate-100 text-slate-600"
  defp action_badge_class(_), do: "bg-slate-100 text-slate-600"
end
