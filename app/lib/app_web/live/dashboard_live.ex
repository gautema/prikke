defmodule PrikkeWeb.DashboardLive do
  use PrikkeWeb, :live_view

  alias Prikke.Accounts
  alias Prikke.Jobs
  alias Prikke.Executions
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

    # Subscribe to job and execution updates if we have an organization
    if current_org && connected?(socket) do
      Jobs.subscribe_jobs(current_org)
      Executions.subscribe_organization_executions(current_org.id)
    end

    recent_jobs = load_recent_jobs(current_org)
    job_ids = Enum.map(recent_jobs, & &1.id)
    latest_statuses = Executions.get_latest_statuses(job_ids)

    socket =
      socket
      |> assign(:current_organization, current_org)
      |> assign(:organizations, organizations)
      |> assign(:pending_invites_count, length(pending_invites))
      |> assign(:stats, load_stats(current_org))
      |> assign(:recent_jobs, recent_jobs)
      |> assign(:latest_statuses, latest_statuses)
      |> assign(:recent_executions, load_recent_executions(current_org))

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

  defp reload_data(socket, org) do
    recent_jobs = load_recent_jobs(org)
    job_ids = Enum.map(recent_jobs, & &1.id)
    latest_statuses = Executions.get_latest_statuses(job_ids)

    socket
    |> assign(:stats, load_stats(org))
    |> assign(:recent_jobs, recent_jobs)
    |> assign(:latest_statuses, latest_statuses)
    |> assign(:recent_executions, load_recent_executions(org))
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
        <!-- Quick Stats -->
        <div class="grid grid-cols-3 gap-4 mb-4">
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
          </div>
          <div class="glass-card rounded-2xl p-6">
            <div class="text-sm font-medium text-slate-500 mb-1">Success Rate</div>
            <div class="text-3xl font-bold text-emerald-600">{@stats.success_rate}</div>
          </div>
        </div>
        
    <!-- Monthly Usage -->
        <div class="glass-card rounded-2xl p-4 mb-8">
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
        
    <!-- Jobs Section -->
        <div class="glass-card rounded-2xl">
          <div class="px-6 py-4 border-b border-white/50 flex justify-between items-center">
            <h2 class="text-lg font-semibold text-slate-900">Jobs</h2>
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
            <div class="p-12 text-center">
              <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-4">
                <.icon name="hero-clock" class="w-6 h-6 text-slate-400" />
              </div>
              <h3 class="text-lg font-medium text-slate-900 mb-1">No jobs yet</h3>
              <p class="text-slate-500 mb-4">Create your first scheduled job to get started.</p>
              <.link navigate={~p"/jobs/new"} class="text-emerald-600 font-medium hover:underline">
                Create a job →
              </.link>
            </div>
          <% else %>
            <div class="divide-y divide-white/30">
              <%= for job <- @recent_jobs do %>
                <.link
                  navigate={~p"/jobs/#{job.id}"}
                  class="block px-6 py-4 hover:bg-slate-50 transition-colors"
                >
                  <div class="flex items-center justify-between">
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <.execution_status_dot status={get_status(@latest_statuses[job.id])} />
                        <span class="font-medium text-slate-900 truncate">{job.name}</span>
                        <.job_status_badge job={job} latest_info={@latest_statuses[job.id]} />
                      </div>
                      <div class="text-sm text-slate-500 mt-0.5 flex items-center gap-2">
                        <span class="font-mono text-xs">{job.method}</span>
                        <span class="truncate">{job.url}</span>
                      </div>
                    </div>
                    <div class="text-xs text-slate-400 ml-4 text-right">
                      <%= if job.schedule_type == "cron" do %>
                        <div>{Cron.describe(job.cron_expression)}</div>
                        <div class="font-mono text-slate-300">{job.cron_expression}</div>
                      <% else %>
                        One-time
                      <% end %>
                    </div>
                  </div>
                </.link>
              <% end %>
            </div>
            <%= if @stats.total_jobs > 5 do %>
              <div class="px-6 py-3 border-t border-slate-200 text-center">
                <.link navigate={~p"/jobs"} class="text-sm text-emerald-600 hover:underline">
                  View all {@stats.total_jobs} jobs →
                </.link>
              </div>
            <% end %>
          <% end %>
        </div>
        
    <!-- Recent Executions -->
        <div class="glass-card rounded-2xl mt-6">
          <div class="px-6 py-4 border-b border-white/50">
            <h2 class="text-lg font-semibold text-slate-900">Recent Executions</h2>
          </div>
          <%= if @recent_executions == [] do %>
            <div class="p-8 text-center text-slate-500">
              No executions yet. Jobs will appear here once they run.
            </div>
          <% else %>
            <div class="divide-y divide-white/30">
              <%= for execution <- @recent_executions do %>
                <.link
                  navigate={~p"/jobs/#{execution.job_id}"}
                  class="block px-6 py-3 hover:bg-slate-50 transition-colors"
                >
                  <div class="flex items-center justify-between">
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <.status_badge status={execution.status} />
                        <span class="font-medium text-slate-900 truncate">{execution.job.name}</span>
                      </div>
                      <div class="text-sm text-slate-500 mt-0.5">
                        <%= if execution.duration_ms do %>
                          <span>{format_duration(execution.duration_ms)}</span>
                          <span class="mx-1">·</span>
                        <% end %>
                        <%= if execution.status_code do %>
                          <span class="font-mono text-xs">{execution.status_code}</span>
                          <span class="mx-1">·</span>
                        <% end %>
                        <.relative_time
                          id={"exec-#{execution.id}"}
                          datetime={execution.scheduled_for}
                        />
                      </div>
                    </div>
                  </div>
                </.link>
              <% end %>
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
      success_rate: "—",
      monthly_executions: 0,
      monthly_limit: 0
    }

  defp load_stats(organization) do
    exec_stats = Executions.get_today_stats(organization)
    tier_limits = Jobs.get_tier_limits(organization.tier)
    monthly_executions = Executions.count_current_month_executions(organization)

    success_rate = calculate_success_rate(exec_stats)

    %{
      active_jobs: Jobs.count_enabled_jobs(organization),
      total_jobs: Jobs.count_jobs(organization),
      executions_today: exec_stats.total,
      success_rate: success_rate,
      monthly_executions: monthly_executions,
      monthly_limit: tier_limits.max_monthly_executions
    }
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

  defp load_recent_jobs(nil), do: []

  defp load_recent_jobs(organization) do
    organization
    |> Jobs.list_jobs()
    |> Enum.take(5)
  end

  defp load_recent_executions(nil), do: []

  defp load_recent_executions(organization) do
    Executions.list_organization_executions(organization, limit: 10)
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

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "text-xs font-medium px-2 py-0.5 rounded",
      status_badge_class(@status)
    ]}>
      {status_label(@status)}
    </span>
    """
  end

  defp status_badge_class("success"), do: "bg-emerald-100 text-emerald-700"
  defp status_badge_class("failed"), do: "bg-red-100 text-red-700"
  defp status_badge_class("timeout"), do: "bg-amber-100 text-amber-700"
  defp status_badge_class("running"), do: "bg-blue-100 text-blue-700"
  defp status_badge_class("pending"), do: "bg-slate-100 text-slate-600"
  defp status_badge_class("missed"), do: "bg-orange-100 text-orange-700"
  defp status_badge_class(_), do: "bg-slate-100 text-slate-600"

  defp status_label("success"), do: "Success"
  defp status_label("failed"), do: "Failed"
  defp status_label("timeout"), do: "Timeout"
  defp status_label("running"), do: "Running"
  defp status_label("pending"), do: "Pending"
  defp status_label("missed"), do: "Missed"
  defp status_label(status), do: status

  defp format_duration(nil), do: nil
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"
end
