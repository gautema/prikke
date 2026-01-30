defmodule PrikkeWeb.SuperadminLive do
  use PrikkeWeb, :live_view

  alias Prikke.Accounts
  alias Prikke.Jobs
  alias Prikke.Executions
  alias Prikke.Analytics
  alias Prikke.Audit

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
      total_jobs: Jobs.count_all_jobs(),
      enabled_jobs: Jobs.count_all_enabled_jobs()
    }

    # Execution stats
    exec_stats = Executions.get_platform_stats()
    success_rate = Executions.get_platform_success_rate(seven_days_ago)

    # Analytics (pageviews)
    analytics = Analytics.get_pageview_stats()

    # Recent activity
    recent_users = Accounts.list_recent_users(limit: 5)
    recent_jobs = Jobs.list_recent_jobs_all(limit: 5)
    active_orgs = Accounts.list_active_organizations(limit: 5)
    recent_executions = Executions.list_recent_executions_all(limit: 10)

    # Pro count for stats
    pro_count = Accounts.count_pro_organizations()

    # Execution trend
    execution_trend = Executions.executions_by_day(14)

    # Monthly executions per org
    org_monthly_executions = Executions.list_organization_monthly_executions(limit: 20)

    # Recent audit logs
    audit_logs = Audit.list_all_logs(limit: 20)

    socket
    |> assign(:platform_stats, platform_stats)
    |> assign(:org_monthly_executions, org_monthly_executions)
    |> assign(:exec_stats, exec_stats)
    |> assign(:success_rate, success_rate)
    |> assign(:analytics, analytics)
    |> assign(:recent_users, recent_users)
    |> assign(:recent_jobs, recent_jobs)
    |> assign(:active_orgs, active_orgs)
    |> assign(:recent_executions, recent_executions)
    |> assign(:pro_count, pro_count)
    |> assign(:execution_trend, execution_trend)
    |> assign(:audit_logs, audit_logs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto py-8 px-4">
      <div class="mb-8">
        <h1 class="text-2xl font-bold text-slate-900">Superadmin Dashboard</h1>
        <p class="text-slate-500 mt-1">Platform-wide analytics and monitoring</p>
      </div>
      
    <!-- Platform Stats -->
      <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
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
          title="Total Jobs"
          value={@platform_stats.total_jobs}
          subtitle={"#{@platform_stats.enabled_jobs} enabled"}
        />
        <.stat_card
          title="Success Rate (7d)"
          value={if @success_rate, do: "#{@success_rate}%", else: "—"}
          color={success_rate_color(@success_rate)}
        />
        <.stat_card title="Pro Customers" value={@pro_count} color="text-emerald-600" />
      </div>
      
    <!-- Execution Stats -->
      <div class="bg-white border border-slate-200 rounded-lg p-6 mb-8">
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
      
    <!-- Execution Trend Chart -->
      <div class="bg-white border border-slate-200 rounded-lg p-6 mb-8">
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
                    <div class="bg-red-400 rounded-t-sm flex-none" style={"height: #{failed_pct}%"}></div>
                  <% end %>
                  <%= if success_pct > 0 && stats.success > 0 do %>
                    <div
                      class={["bg-emerald-500 flex-1", if(stats.failed == 0, do: "rounded-t-sm", else: "")]}
                    >
                    </div>
                  <% end %>
                  <%= if stats.total == 0 do %>
                    <div class="bg-slate-100 h-1 rounded-sm"></div>
                  <% end %>
                </div>
                <!-- Tooltip -->
                <div class={[
                  "hidden group-hover:block absolute bottom-full mb-2 px-2 py-1 bg-slate-800 text-white text-xs rounded whitespace-nowrap z-10",
                  if(idx < 3, do: "left-0", else: if(idx > 10, do: "right-0", else: "left-1/2 -translate-x-1/2"))
                ]}>
                  <div class="font-medium">{Calendar.strftime(date, "%b %d")}</div>
                  <div>{stats.total} total</div>
                  <%= if stats.success > 0 do %><div class="text-emerald-400">{stats.success} success</div><% end %>
                  <%= if stats.failed > 0 do %><div class="text-red-400">{stats.failed} failed</div><% end %>
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
        <div class="bg-white border border-slate-200 rounded-lg p-6">
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
        <div class="bg-white border border-slate-200 rounded-lg p-6">
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
      <div class="bg-white border border-slate-200 rounded-lg p-6 mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-lg font-semibold text-slate-900">Monthly Executions by Organization</h2>
          <span class="text-sm text-slate-500">{Calendar.strftime(DateTime.utc_now(), "%B %Y")}</span>
        </div>
        <div class="overflow-x-auto">
          <table class="min-w-full">
            <thead>
              <tr class="border-b border-slate-200">
                <th class="py-2 text-left text-sm font-medium text-slate-500">Organization</th>
                <th class="py-2 text-left text-sm font-medium text-slate-500">Tier</th>
                <th class="py-2 text-right text-sm font-medium text-slate-500">Executions</th>
                <th class="py-2 text-right text-sm font-medium text-slate-500">Limit</th>
                <th class="py-2 text-right text-sm font-medium text-slate-500">Usage</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-slate-100">
              <%= for {org, count, limit} <- @org_monthly_executions do %>
                <% usage_pct = Float.round(count / limit * 100, 1) %>
                <tr>
                  <td class="py-2 font-medium text-slate-900">{org.name}</td>
                  <td class="py-2">
                    <span class={[
                      "text-xs px-2 py-0.5 rounded-full",
                      if(org.tier == "pro", do: "bg-emerald-100 text-emerald-700", else: "bg-slate-100 text-slate-600")
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
        <div class="bg-white border border-slate-200 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Recent Signups</h2>
          <div class="space-y-3">
            <%= for user <- @recent_users do %>
              <div class="flex justify-between items-center">
                <span class="text-slate-900">{user.email}</span>
                <span class="text-xs text-slate-400">
                  <.relative_time id={"user-#{user.id}"} datetime={user.inserted_at} />
                </span>
              </div>
            <% end %>
            <%= if @recent_users == [] do %>
              <div class="text-sm text-slate-400">No users yet</div>
            <% end %>
          </div>
        </div>
        
    <!-- Recent Jobs -->
        <div class="bg-white border border-slate-200 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Recent Jobs</h2>
          <div class="space-y-3">
            <%= for job <- @recent_jobs do %>
              <div class="flex justify-between items-center">
                <div class="min-w-0 flex-1 mr-2">
                  <div class="font-medium text-slate-900 truncate">{job.name}</div>
                  <div class="text-xs text-slate-500 truncate">
                    {job.organization && job.organization.name}
                  </div>
                </div>
                <span class="text-xs text-slate-400 shrink-0">
                  <.relative_time id={"job-#{job.id}"} datetime={job.inserted_at} />
                </span>
              </div>
            <% end %>
            <%= if @recent_jobs == [] do %>
              <div class="text-sm text-slate-400">No jobs yet</div>
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Recent Executions & Audit Logs -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
        <!-- Recent Executions -->
        <div class="bg-white border border-slate-200 rounded-lg">
          <div class="px-6 py-4 border-b border-slate-200">
            <h2 class="text-lg font-semibold text-slate-900">Recent Executions</h2>
          </div>
          <div class="divide-y divide-slate-200">
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
        <div class="bg-white border border-slate-200 rounded-lg">
          <div class="px-6 py-4 border-b border-slate-200">
            <h2 class="text-lg font-semibold text-slate-900">Recent Audit Logs</h2>
          </div>
          <div class="divide-y divide-slate-200">
            <%= for log <- @audit_logs do %>
              <div class="px-6 py-3">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <span class={["text-xs px-2 py-0.5 rounded-full font-medium", action_badge_class(log.action)]}>
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
    </div>

    <.footer />
    """
  end

  defp stat_card(assigns) do
    assigns = assign_new(assigns, :subtitle, fn -> nil end)
    assigns = assign_new(assigns, :color, fn -> "text-slate-900" end)

    ~H"""
    <div class="bg-white border border-slate-200 rounded-lg p-4">
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

  defp status_dot_color("success"), do: "bg-emerald-500"
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
