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
      latest_info = get_latest_info(executions)
      if connected?(socket), do: Jobs.subscribe_jobs(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:job, job)
       |> assign(:executions, executions)
       |> assign(:stats, stats)
       |> assign(:latest_info, latest_info)
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
      latest_info = get_latest_info(executions)

      {:noreply,
       socket
       |> assign(:job, job)
       |> assign(:executions, executions)
       |> assign(:stats, stats)
       |> assign(:latest_info, latest_info)}
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
    require Logger
    job = socket.assigns.job
    Logger.info("[JobLive.Show] Toggle event for job #{job.id}, currently enabled=#{job.enabled}")

    case Jobs.toggle_job(socket.assigns.organization, job) do
      {:ok, updated_job} ->
        Logger.info("[JobLive.Show] Toggle succeeded, now enabled=#{updated_job.enabled}")
        {:noreply, assign(socket, :job, updated_job)}

      {:error, changeset} ->
        Logger.warning("[JobLive.Show] Toggle failed: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to toggle job")}
    end
  end

  def handle_event("delete", _, socket) do
    {:ok, _} = Jobs.delete_job(socket.assigns.organization, socket.assigns.job)

    {:noreply,
     socket
     |> put_flash(:info, "Job deleted successfully")
     |> redirect(to: ~p"/jobs")}
  end

  def handle_event("run_now", _, socket) do
    job = socket.assigns.job
    scheduled_for = DateTime.utc_now() |> DateTime.truncate(:second)

    case Executions.create_execution_for_job(job, scheduled_for) do
      {:ok, _execution} ->
        # Wake workers to process immediately
        Jobs.notify_workers()

        # Refresh executions list
        executions = Executions.list_job_executions(job, limit: 20)
        stats = Executions.get_job_stats(job)
        latest_info = get_latest_info(executions)

        {:noreply,
         socket
         |> assign(:executions, executions)
         |> assign(:stats, stats)
         |> assign(:latest_info, latest_info)
         |> put_flash(:info, "Job queued for immediate execution")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue job")}
    end
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-6 sm:py-8 px-4">
      <div class="mb-4 sm:mb-6">
        <.link
          navigate={~p"/dashboard"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Dashboard
        </.link>
      </div>

      <div class="bg-white border border-slate-200 rounded-lg">
        <div class="px-4 sm:px-6 py-4 border-b border-slate-200">
          <div class="flex flex-col sm:flex-row sm:justify-between sm:items-start gap-4">
            <div>
              <div class="flex items-center gap-3 flex-wrap">
                <h1 class="text-lg sm:text-xl font-bold text-slate-900">{@job.name}</h1>
                <.job_status_badge job={@job} latest_info={@latest_info} />
              </div>
              <p class="text-sm text-slate-500 mt-1">
                Created {Calendar.strftime(@job.inserted_at, "%d %b %Y")}
              </p>
            </div>
            <div class="flex items-center gap-2 flex-wrap">
              <button
                type="button"
                phx-click="run_now"
                class="px-3 py-1.5 text-sm font-medium text-white bg-emerald-500 hover:bg-emerald-600 rounded-md transition-colors cursor-pointer flex items-center gap-1.5"
              >
                <.icon name="hero-play" class="w-4 h-4" /> Run Now
              </button>
              <%= if @job.schedule_type == "cron" do %>
                <button
                  type="button"
                  phx-click="toggle"
                  class={[
                    "px-3 py-1.5 text-sm font-medium rounded-md transition-colors cursor-pointer",
                    @job.enabled && "text-slate-600 bg-slate-100 hover:bg-slate-200",
                    !@job.enabled && "text-emerald-600 bg-emerald-100 hover:bg-emerald-200"
                  ]}
                >
                  {if @job.enabled, do: "Pause", else: "Enable"}
                </button>
              <% end %>
              <.link
                navigate={~p"/jobs/#{@job.id}/edit"}
                class="px-3 py-1.5 text-sm font-medium text-slate-600 bg-slate-100 hover:bg-slate-200 rounded-md transition-colors"
              >
                Edit
              </.link>
              <button
                type="button"
                phx-click="delete"
                data-confirm="Are you sure you want to delete this job? This cannot be undone."
                class="px-3 py-1.5 text-sm font-medium text-red-600 bg-red-50 hover:bg-red-100 rounded-md transition-colors cursor-pointer"
              >
                Delete
              </button>
            </div>
          </div>
        </div>

        <div class="p-4 sm:p-6 space-y-6">
          <!-- Webhook Details -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Webhook</h3>
            <div class="bg-slate-50 rounded-lg p-3 sm:p-4 space-y-3">
              <div class="flex items-start sm:items-center gap-2 flex-col sm:flex-row">
                <span class="font-mono text-sm bg-slate-200 px-2 py-1 rounded font-medium shrink-0">
                  {@job.method}
                </span>
                <code class="text-sm text-slate-700 break-all">{@job.url}</code>
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
            <div class="bg-slate-50 rounded-lg p-3 sm:p-4">
              <%= if @job.schedule_type == "cron" do %>
                <div class="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3">
                  <span class="font-mono text-base sm:text-lg bg-slate-200 px-3 py-1 rounded w-fit">
                    {@job.cron_expression}
                  </span>
                  <span class="text-slate-600">{describe_cron(@job.cron_expression)}</span>
                </div>
                <p class="text-sm text-slate-500 mt-2">Timezone: {@job.timezone}</p>
              <% else %>
                <div>
                  <span class="text-slate-900 font-medium">One-time execution</span>
                  <p class="text-slate-600 mt-1">
                    Scheduled for {Calendar.strftime(@job.scheduled_at, "%d %B %Y at %H:%M")} UTC
                  </p>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Settings -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Settings</h3>
            <div class="bg-slate-50 rounded-lg p-3 sm:p-4 grid grid-cols-2 gap-4">
              <div>
                <span class="text-xs text-slate-500 uppercase">Timeout</span>
                <p class="text-slate-900">{format_timeout(@job.timeout_ms)}</p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Retry Attempts</span>
                <p class="text-slate-900">{@job.retry_attempts}</p>
              </div>
            </div>
          </div>
          
    <!-- Stats (24h) -->
          <%= if @stats.total > 0 do %>
            <div>
              <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">
                Last 24 Hours
              </h3>
              <div class="bg-slate-50 rounded-lg p-3 sm:p-4 grid grid-cols-2 sm:grid-cols-4 gap-4">
                <div>
                  <span class="text-xs text-slate-500 uppercase">Total</span>
                  <p class="text-xl font-bold text-slate-900">{@stats.total}</p>
                </div>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Success</span>
                  <p class="text-xl font-bold text-emerald-600">{@stats.success}</p>
                </div>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Failed</span>
                  <p class="text-xl font-bold text-red-600">{@stats.failed + @stats.timeout}</p>
                </div>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Avg Duration</span>
                  <p class="text-xl font-bold text-slate-900">
                    {format_avg_duration(@stats.avg_duration_ms)}
                  </p>
                </div>
              </div>
            </div>
          <% end %>
          
    <!-- Recent Executions -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">
              Recent Executions
            </h3>
            <%= if @executions == [] do %>
              <div class="bg-slate-50 rounded-lg p-6 sm:p-8 text-center text-slate-500">
                No executions yet. This job will run according to its schedule.
              </div>
            <% else %>
              <div class="bg-slate-50 rounded-lg overflow-hidden divide-y divide-slate-200">
                <%= for exec <- @executions do %>
                  <.link
                    navigate={~p"/jobs/#{@job.id}/executions/#{exec.id}"}
                    class="block px-4 py-3 hover:bg-slate-100 transition-colors"
                  >
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-3">
                        <.status_badge status={exec.status} />
                        <span class="text-sm text-slate-600">
                          {format_execution_time(exec.scheduled_for)}
                        </span>
                      </div>
                      <div class="flex items-center gap-4 text-sm text-slate-500">
                        <span>{format_duration(exec.duration_ms)}</span>
                        <%= if exec.status_code do %>
                          <span class={[
                            "font-mono",
                            status_code_color(exec.status_code)
                          ]}>
                            {exec.status_code}
                          </span>
                        <% end %>
                        <.icon name="hero-chevron-right" class="w-4 h-4 text-slate-400" />
                      </div>
                    </div>
                    <%= if exec.error_message do %>
                      <p class="text-red-600 text-xs mt-1 pl-0 sm:pl-16">
                        {truncate(exec.error_message, 60)}
                      </p>
                    <% end %>
                  </.link>
                <% end %>
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

  defp get_latest_info([]), do: nil
  defp get_latest_info([exec | _]), do: %{status: exec.status, attempt: exec.attempt}

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

  defp status_code_color(code) when code >= 200 and code < 300, do: "text-emerald-600"
  defp status_code_color(code) when code >= 300 and code < 400, do: "text-blue-600"
  defp status_code_color(code) when code >= 400 and code < 500, do: "text-amber-600"
  defp status_code_color(_), do: "text-red-600"

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
    Calendar.strftime(datetime, "%d %b, %H:%M:%S")
  end

  defp truncate(nil, _), do: nil
  defp truncate(string, max) when byte_size(string) <= max, do: string
  defp truncate(string, max), do: String.slice(string, 0, max) <> "..."
end
