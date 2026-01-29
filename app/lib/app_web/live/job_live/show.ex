defmodule PrikkeWeb.JobLive.Show do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs
  alias Prikke.Executions

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      job = Jobs.get_job!(org, id)
      executions = Executions.list_job_executions(job, limit: 20)
      stats = Executions.get_job_stats(job)
      if connected?(socket), do: Jobs.subscribe_jobs(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:job, job)
       |> assign(:executions, executions)
       |> assign(:stats, stats)
       |> assign(:page_title, job.name)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_info({:updated, job}, socket) do
    if job.id == socket.assigns.job.id do
      executions = Executions.list_job_executions(job, limit: 20)
      stats = Executions.get_job_stats(job)
      {:noreply,
       socket
       |> assign(:job, job)
       |> assign(:executions, executions)
       |> assign(:stats, stats)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:deleted, job}, socket) do
    if job.id == socket.assigns.job.id do
      {:noreply,
       socket
       |> put_flash(:info, "Job was deleted")
       |> redirect(to: ~p"/jobs")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle", _, socket) do
    {:ok, job} = Jobs.toggle_job(socket.assigns.organization, socket.assigns.job)
    {:noreply, assign(socket, :job, job)}
  end

  def handle_event("delete", _, socket) do
    {:ok, _} = Jobs.delete_job(socket.assigns.organization, socket.assigns.job)

    {:noreply,
     socket
     |> put_flash(:info, "Job deleted successfully")
     |> redirect(to: ~p"/jobs")}
  end

  defp get_organization(socket, session) do
    user = socket.assigns.current_scope.user
    org_id = session["current_organization_id"]

    if org_id do
      Prikke.Accounts.get_organization(org_id)
    else
      case Prikke.Accounts.list_user_organizations(user) do
        [org | _] -> org
        [] -> nil
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">
      <div class="mb-6">
        <.link navigate={~p"/jobs"} class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1">
          <.icon name="hero-chevron-left" class="w-4 h-4" />
          Back to Jobs
        </.link>
      </div>

      <div class="bg-white border border-slate-200 rounded-lg">
        <div class="px-6 py-4 border-b border-slate-200 flex justify-between items-start">
          <div>
            <div class="flex items-center gap-3">
              <h1 class="text-xl font-bold text-slate-900"><%= @job.name %></h1>
              <.job_status_badge job={@job} />
            </div>
            <p class="text-sm text-slate-500 mt-1">Created <%= Calendar.strftime(@job.inserted_at, "%b %d, %Y") %></p>
          </div>
          <div class="flex items-center gap-2">
            <%= unless job_completed?(@job) do %>
              <button
                phx-click="toggle"
                class={[
                  "px-3 py-1.5 text-sm font-medium rounded-md transition-colors",
                  @job.enabled && "text-slate-600 bg-slate-100 hover:bg-slate-200",
                  !@job.enabled && "text-emerald-600 bg-emerald-100 hover:bg-emerald-200"
                ]}
              >
                <%= if @job.enabled, do: "Pause", else: "Enable" %>
              </button>
            <% end %>
            <.link
              navigate={~p"/jobs/#{@job.id}/edit"}
              class="px-3 py-1.5 text-sm font-medium text-slate-600 bg-slate-100 hover:bg-slate-200 rounded-md transition-colors"
            >
              Edit
            </.link>
            <button
              phx-click="delete"
              data-confirm="Are you sure you want to delete this job? This cannot be undone."
              class="px-3 py-1.5 text-sm font-medium text-red-600 bg-red-50 hover:bg-red-100 rounded-md transition-colors"
            >
              Delete
            </button>
          </div>
        </div>

        <div class="p-6 space-y-6">
          <!-- Webhook Details -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Webhook</h3>
            <div class="bg-slate-50 rounded-lg p-4 space-y-3">
              <div class="flex items-center gap-2">
                <span class="font-mono text-sm bg-slate-200 px-2 py-1 rounded font-medium"><%= @job.method %></span>
                <code class="text-sm text-slate-700 break-all"><%= @job.url %></code>
              </div>
              <%= if @job.headers && @job.headers != %{} do %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Headers</span>
                  <pre class="text-xs bg-slate-100 p-2 rounded mt-1 overflow-x-auto"><%= Jason.encode!(@job.headers, pretty: true) %></pre>
                </div>
              <% end %>
              <%= if @job.body && @job.body != "" do %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Body</span>
                  <pre class="text-xs bg-slate-100 p-2 rounded mt-1 overflow-x-auto"><%= @job.body %></pre>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Schedule -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Schedule</h3>
            <div class="bg-slate-50 rounded-lg p-4">
              <%= if @job.schedule_type == "cron" do %>
                <div class="flex items-center gap-3">
                  <span class="font-mono text-lg bg-slate-200 px-3 py-1 rounded"><%= @job.cron_expression %></span>
                  <span class="text-slate-600"><%= describe_cron(@job.cron_expression) %></span>
                </div>
                <p class="text-sm text-slate-500 mt-2">Timezone: <%= @job.timezone %></p>
              <% else %>
                <div>
                  <span class="text-slate-900 font-medium">One-time execution</span>
                  <p class="text-slate-600 mt-1">
                    Scheduled for <%= Calendar.strftime(@job.scheduled_at, "%B %d, %Y at %H:%M") %> UTC
                  </p>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Settings -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Settings</h3>
            <div class="bg-slate-50 rounded-lg p-4 grid grid-cols-2 gap-4">
              <div>
                <span class="text-xs text-slate-500 uppercase">Timeout</span>
                <p class="text-slate-900"><%= format_timeout(@job.timeout_ms) %></p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Retry Attempts</span>
                <p class="text-slate-900"><%= @job.retry_attempts %></p>
              </div>
            </div>
          </div>

          <!-- Stats (24h) -->
          <%= if @stats.total > 0 do %>
            <div>
              <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Last 24 Hours</h3>
              <div class="bg-slate-50 rounded-lg p-4 grid grid-cols-4 gap-4">
                <div>
                  <span class="text-xs text-slate-500 uppercase">Total</span>
                  <p class="text-xl font-bold text-slate-900"><%= @stats.total %></p>
                </div>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Success</span>
                  <p class="text-xl font-bold text-emerald-600"><%= @stats.success %></p>
                </div>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Failed</span>
                  <p class="text-xl font-bold text-red-600"><%= @stats.failed + @stats.timeout %></p>
                </div>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Avg Duration</span>
                  <p class="text-xl font-bold text-slate-900"><%= format_avg_duration(@stats.avg_duration_ms) %></p>
                </div>
              </div>
            </div>
          <% end %>

          <!-- Recent Executions -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Recent Executions</h3>
            <%= if @executions == [] do %>
              <div class="bg-slate-50 rounded-lg p-8 text-center text-slate-500">
                No executions yet. This job will run according to its schedule.
              </div>
            <% else %>
              <div class="bg-slate-50 rounded-lg overflow-hidden">
                <table class="w-full text-sm">
                  <thead>
                    <tr class="border-b border-slate-200 text-left">
                      <th class="px-4 py-2 font-medium text-slate-500">Status</th>
                      <th class="px-4 py-2 font-medium text-slate-500">Time</th>
                      <th class="px-4 py-2 font-medium text-slate-500">Duration</th>
                      <th class="px-4 py-2 font-medium text-slate-500">Response</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-slate-200">
                    <%= for exec <- @executions do %>
                      <tr class="hover:bg-slate-100">
                        <td class="px-4 py-2">
                          <.status_badge status={exec.status} />
                        </td>
                        <td class="px-4 py-2 text-slate-600">
                          <%= format_execution_time(exec.scheduled_for) %>
                        </td>
                        <td class="px-4 py-2 text-slate-600">
                          <%= format_duration(exec.duration_ms) %>
                        </td>
                        <td class="px-4 py-2 text-slate-600">
                          <%= if exec.status_code do %>
                            <span class="font-mono"><%= exec.status_code %></span>
                          <% end %>
                          <%= if exec.error_message do %>
                            <span class="text-red-600 text-xs"><%= truncate(exec.error_message, 50) %></span>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp describe_cron(expression) do
    case expression do
      "* * * * *" -> "Every minute"
      "*/5 * * * *" -> "Every 5 minutes"
      "*/15 * * * *" -> "Every 15 minutes"
      "*/30 * * * *" -> "Every 30 minutes"
      "0 * * * *" -> "Every hour"
      "0 */2 * * *" -> "Every 2 hours"
      "0 */6 * * *" -> "Every 6 hours"
      "0 */12 * * *" -> "Every 12 hours"
      "0 0 * * *" -> "Daily at midnight"
      "0 9 * * *" -> "Daily at 9:00 AM"
      "0 0 * * 0" -> "Weekly on Sunday"
      "0 0 1 * *" -> "Monthly on the 1st"
      _ -> "Custom schedule"
    end
  end

  defp format_timeout(ms) do
    cond do
      ms >= 60_000 -> "#{div(ms, 60_000)} minute(s)"
      ms >= 1000 -> "#{div(ms, 1000)} second(s)"
      true -> "#{ms}ms"
    end
  end

  defp job_completed?(job) do
    job.schedule_type == "once" and is_nil(job.next_run_at)
  end

  defp job_status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% job_completed?(@job) -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-slate-100 text-slate-600">Completed</span>
      <% @job.enabled -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-emerald-100 text-emerald-700">Active</span>
      <% true -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-amber-100 text-amber-700">Paused</span>
    <% end %>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "text-xs font-medium px-2 py-0.5 rounded",
      status_badge_class(@status)
    ]}>
      <%= status_label(@status) %>
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

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_avg_duration(nil), do: "—"
  defp format_avg_duration(ms) do
    ms = Decimal.to_float(ms)
    format_duration(round(ms))
  end

  defp format_execution_time(nil), do: "—"
  defp format_execution_time(datetime) do
    Calendar.strftime(datetime, "%b %d, %H:%M:%S")
  end

  defp truncate(nil, _), do: nil
  defp truncate(string, max) when byte_size(string) <= max, do: string
  defp truncate(string, max), do: String.slice(string, 0, max) <> "..."
end
