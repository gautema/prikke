defmodule PrikkeWeb.SuperadminLive do
  use PrikkeWeb, :live_view

  alias Prikke.Accounts
  alias Prikke.Jobs
  alias Prikke.Executions
  alias Prikke.Analytics

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

    # Pro organizations
    pro_orgs = Accounts.list_pro_organizations(limit: 10)
    pro_count = Accounts.count_pro_organizations()

    # Execution trend
    execution_trend = Executions.executions_by_day(14)

    socket
    |> assign(:platform_stats, platform_stats)
    |> assign(:exec_stats, exec_stats)
    |> assign(:success_rate, success_rate)
    |> assign(:analytics, analytics)
    |> assign(:recent_users, recent_users)
    |> assign(:recent_jobs, recent_jobs)
    |> assign(:active_orgs, active_orgs)
    |> assign(:recent_executions, recent_executions)
    |> assign(:pro_orgs, pro_orgs)
    |> assign(:pro_count, pro_count)
    |> assign(:execution_trend, execution_trend)
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
        <div class="h-32 flex items-end gap-1">
          <%= for {_date, stats} <- @execution_trend do %>
            <% max_val =
              Enum.max_by(@execution_trend, fn {_, s} -> s.total end)
              |> elem(1)
              |> Map.get(:total)
              |> max(1) %>
            <% height = if stats.total > 0, do: max(round(stats.total / max_val * 100), 4), else: 0 %>
            <% success_height =
              if stats.total > 0, do: round(stats.success / stats.total * height), else: 0 %>
            <% failed_height = height - success_height %>
            <div
              class="flex-1 flex flex-col justify-end"
              title={"#{stats.total} total, #{stats.success} success, #{stats.failed} failed"}
            >
              <%= if failed_height > 0 do %>
                <div class="bg-red-400 rounded-t-sm" style={"height: #{failed_height}%"}></div>
              <% end %>
              <%= if success_height > 0 do %>
                <div
                  class={["bg-emerald-500", if(failed_height == 0, do: "rounded-t-sm", else: "")]}
                  style={"height: #{success_height}%"}
                >
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
        <div class="flex justify-between mt-2 text-xs text-slate-400">
          <span>14 days ago</span>
          <span>Today</span>
        </div>
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
      
    <!-- Pro Organizations -->
      <div class="bg-white border border-slate-200 rounded-lg p-6 mb-8">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-lg font-semibold text-slate-900">Pro Organizations</h2>
          <span class="text-sm text-emerald-600 font-medium">{@pro_count} total</span>
        </div>
        <div class="space-y-3">
          <%= for org <- @pro_orgs do %>
            <div class="flex justify-between items-center py-2 border-b border-slate-100 last:border-0">
              <div>
                <div class="font-medium text-slate-900">{org.name}</div>
                <div class="text-sm text-slate-500">{org.owner_email}</div>
              </div>
              <div class="text-xs text-slate-400">
                Upgraded <.relative_time id={"pro-#{org.id}"} datetime={org.upgraded_at} />
              </div>
            </div>
          <% end %>
          <%= if @pro_orgs == [] do %>
            <div class="text-sm text-slate-400 py-4 text-center">No Pro organizations yet</div>
          <% end %>
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
      
    <!-- Recent Executions -->
      <div class="bg-white border border-slate-200 rounded-lg mb-8">
        <div class="px-6 py-4 border-b border-slate-200">
          <h2 class="text-lg font-semibold text-slate-900">Recent Executions</h2>
        </div>
        <div class="divide-y divide-slate-200">
          <%= for execution <- @recent_executions do %>
            <div class="px-6 py-3 flex items-center justify-between">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <.status_dot status={execution.status} />
                  <span class="font-medium text-slate-900 truncate">
                    {execution.job && execution.job.name}
                  </span>
                  <span class="text-xs text-slate-400">
                    {execution.job && execution.job.organization && execution.job.organization.name}
                  </span>
                </div>
                <div class="text-xs text-slate-500 mt-0.5">
                  <%= if execution.duration_ms do %>
                    {format_duration(execution.duration_ms)}
                    <span class="mx-1">·</span>
                  <% end %>
                  <%= if execution.status_code do %>
                    <span class="font-mono">{execution.status_code}</span>
                    <span class="mx-1">·</span>
                  <% end %>
                  <.relative_time id={"exec-#{execution.id}"} datetime={execution.scheduled_for} />
                </div>
              </div>
            </div>
          <% end %>
          <%= if @recent_executions == [] do %>
            <div class="px-6 py-8 text-center text-slate-400">No executions yet</div>
          <% end %>
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
end
