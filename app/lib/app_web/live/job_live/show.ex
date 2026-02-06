defmodule PrikkeWeb.JobLive.Show do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs
  alias Prikke.Executions

  @per_page 20

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      case Jobs.get_job(org, id) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Job not found")
           |> redirect(to: ~p"/jobs")}

        job ->
          status_filter = nil
          executions = Executions.list_job_executions(job, limit: @per_page, status: status_filter)
          total_count = Executions.count_job_executions(job, status: status_filter)
          stats = Executions.get_job_stats(job)
          latest_info = get_latest_info(executions)

          if connected?(socket) do
            Jobs.subscribe_jobs(org)
            Executions.subscribe_job_executions(job.id)
          end

          {:ok,
           socket
           |> assign(:organization, org)
           |> assign(:job, job)
           |> assign(:executions, executions)
           |> assign(:stats, stats)
           |> assign(:latest_info, latest_info)
           |> assign(:status_filter, status_filter)
           |> assign(:total_count, total_count)
           |> assign(:page_title, job.name)
           |> assign(:menu_open, false)
           |> assign(:test_result, nil)
           |> assign(:testing, false)}
      end
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
      status_filter = socket.assigns.status_filter
      executions = Executions.list_job_executions(job, limit: @per_page, status: status_filter)
      total_count = Executions.count_job_executions(job, status: status_filter)
      stats = Executions.get_job_stats(job)
      latest_info = get_latest_info(executions)

      {:noreply,
       socket
       |> assign(:job, job)
       |> assign(:executions, executions)
       |> assign(:total_count, total_count)
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

  def handle_info({:execution_updated, _execution}, socket) do
    # Refresh executions list when any execution for this job changes
    job = socket.assigns.job
    status_filter = socket.assigns.status_filter
    executions = Executions.list_job_executions(job, limit: @per_page, status: status_filter)
    total_count = Executions.count_job_executions(job, status: status_filter)
    stats = Executions.get_job_stats(job)
    latest_info = get_latest_info(executions)

    {:noreply,
     socket
     |> assign(:executions, executions)
     |> assign(:total_count, total_count)
     |> assign(:stats, stats)
     |> assign(:latest_info, latest_info)}
  end

  def handle_info({ref, result}, socket) when is_reference(ref) do
    if ref == socket.assigns[:test_task_ref] do
      Process.demonitor(ref, [:flush])
      {:noreply, assign(socket, test_result: result, testing: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) when is_reference(ref) do
    if ref == socket.assigns[:test_task_ref] do
      {:noreply, assign(socket, testing: false)}
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

    case Jobs.toggle_job(socket.assigns.organization, job, scope: socket.assigns.current_scope) do
      {:ok, updated_job} ->
        Logger.info("[JobLive.Show] Toggle succeeded, now enabled=#{updated_job.enabled}")
        {:noreply, assign(socket, :job, updated_job)}

      {:error, changeset} ->
        Logger.warning("[JobLive.Show] Toggle failed: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to toggle job")}
    end
  end

  def handle_event("toggle_menu", _, socket) do
    {:noreply, assign(socket, :menu_open, !socket.assigns.menu_open)}
  end

  def handle_event("close_menu", _, socket) do
    {:noreply, assign(socket, :menu_open, false)}
  end

  def handle_event("toggle_mute", _, socket) do
    job = socket.assigns.job
    org = socket.assigns.organization

    case Jobs.update_job(org, job, %{muted: !job.muted}) do
      {:ok, updated_job} ->
        {:noreply, assign(socket, :job, updated_job)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update mute setting")}
    end
  end

  def handle_event("clone", _, socket) do
    org = socket.assigns.organization
    job = socket.assigns.job

    case Jobs.clone_job(org, job, scope: socket.assigns.current_scope) do
      {:ok, cloned_job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job cloned successfully")
         |> push_navigate(to: ~p"/jobs/#{cloned_job.id}")}

      {:error, changeset} ->
        message =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {_field, msgs} -> Enum.join(msgs, ", ") end)

        {:noreply, put_flash(socket, :error, "Failed to clone job: #{message}")}
    end
  end

  def handle_event("test_url", _, socket) do
    job = socket.assigns.job

    task =
      Task.async(fn ->
        Jobs.test_webhook(%{
          url: job.url,
          method: job.method,
          headers: job.headers || %{},
          body: job.body,
          timeout_ms: job.timeout_ms
        })
      end)

    {:noreply,
     socket
     |> assign(:testing, true)
     |> assign(:test_result, nil)
     |> assign(:test_task_ref, task.ref)}
  end

  def handle_event("dismiss_test_result", _, socket) do
    {:noreply, assign(socket, :test_result, nil)}
  end

  def handle_event("delete", _, socket) do
    {:ok, _} =
      Jobs.delete_job(socket.assigns.organization, socket.assigns.job,
        scope: socket.assigns.current_scope
      )

    {:noreply,
     socket
     |> put_flash(:info, "Job deleted successfully")
     |> redirect(to: ~p"/jobs")}
  end

  def handle_event("run_now", _, socket) do
    job = socket.assigns.job
    scheduled_for = DateTime.utc_now() |> DateTime.truncate(:second)

    # If this is a retry (last execution failed), make it single-attempt
    opts = if get_status(socket.assigns.latest_info) in ["failed", "timeout"] do
      [attempt: job.retry_attempts]
    else
      []
    end

    case Executions.create_execution_for_job(job, scheduled_for, opts) do
      {:ok, _execution} ->
        # Wake workers to process immediately
        Jobs.notify_workers()

        # Refresh executions list
        status_filter = socket.assigns.status_filter
        executions = Executions.list_job_executions(job, limit: @per_page, status: status_filter)
        total_count = Executions.count_job_executions(job, status: status_filter)
        stats = Executions.get_job_stats(job)
        latest_info = get_latest_info(executions)

        {:noreply,
         socket
         |> assign(:executions, executions)
         |> assign(:total_count, total_count)
         |> assign(:stats, stats)
         |> assign(:latest_info, latest_info)
         |> put_flash(:info, "Job queued for immediate execution")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue job")}
    end
  end

  def handle_event("filter", %{"status" => status}, socket) do
    job = socket.assigns.job
    status_filter = if status == "", do: nil, else: status
    executions = Executions.list_job_executions(job, limit: @per_page, status: status_filter)
    total_count = Executions.count_job_executions(job, status: status_filter)

    {:noreply,
     socket
     |> assign(:status_filter, status_filter)
     |> assign(:executions, executions)
     |> assign(:total_count, total_count)}
  end

  def handle_event("load_more", _, socket) do
    job = socket.assigns.job
    status_filter = socket.assigns.status_filter
    current_count = length(socket.assigns.executions)

    more_executions =
      Executions.list_job_executions(job,
        limit: @per_page,
        offset: current_count,
        status: status_filter
      )

    {:noreply,
     socket
     |> assign(:executions, socket.assigns.executions ++ more_executions)}
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

      <div class="glass-card rounded-2xl">
        <div class="px-4 sm:px-6 py-4 border-b border-white/50">
          <div class="flex flex-col sm:flex-row sm:justify-between sm:items-start gap-4">
            <div>
              <div class="flex items-center gap-3 flex-wrap">
                <h1 class="text-lg sm:text-xl font-bold text-slate-900">{@job.name}</h1>
                <%= if @job.muted do %>
                  <span class="inline-flex items-center gap-1 text-xs font-medium px-2 py-0.5 rounded bg-slate-100 text-slate-500" title="Notifications muted">
                    <.icon name="hero-bell-slash" class="w-3.5 h-3.5" /> Muted
                  </span>
                <% end %>
                <.job_status_badge job={@job} latest_info={@latest_info} />
              </div>
              <p class="text-sm text-slate-500 mt-1">
                Created <.local_time id="job-created" datetime={@job.inserted_at} format="date" />
              </p>
            </div>
            <div class="flex items-center gap-2">
              <button
                type="button"
                id="test-url-btn"
                phx-click="test_url"
                disabled={@testing}
                class={[
                  "px-3 py-1.5 text-sm font-medium rounded-md transition-colors flex items-center gap-1.5 cursor-pointer",
                  !@testing && "text-slate-700 bg-white border border-slate-200 hover:bg-slate-50",
                  @testing && "text-slate-400 bg-slate-50 border border-slate-100 cursor-not-allowed"
                ]}
              >
                <%= if @testing do %>
                  <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" /> Testing...
                <% else %>
                  <.icon name="hero-signal" class="w-4 h-4" /> Test
                <% end %>
              </button>
              <button
                type="button"
                phx-click="run_now"
                class="px-3 py-1.5 text-sm font-medium text-white bg-emerald-600 hover:bg-emerald-700 rounded-md transition-colors cursor-pointer flex items-center gap-1.5"
              >
                <%= if get_status(@latest_info) in ["failed", "timeout"] do %>
                  <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry
                <% else %>
                  <.icon name="hero-play" class="w-4 h-4" /> Run Now
                <% end %>
              </button>
              <div class="relative" id="job-actions-menu" phx-hook=".ClickOutside">
                <button
                  type="button"
                  phx-click="toggle_menu"
                  class="p-1.5 text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded-md transition-colors cursor-pointer"
                  aria-label="More actions"
                >
                  <.icon name="hero-ellipsis-vertical" class="w-5 h-5" />
                </button>
                <%= if @menu_open do %>
                  <div class="absolute right-0 top-full mt-1 w-44 bg-white rounded-lg shadow-lg border border-slate-200 py-1 z-50">
                    <%= if @job.schedule_type == "cron" do %>
                      <button
                        type="button"
                        phx-click="toggle"
                        class="w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50 flex items-center gap-2 cursor-pointer"
                      >
                        <%= if @job.enabled do %>
                          <.icon name="hero-pause" class="w-4 h-4 text-slate-400" /> Pause
                        <% else %>
                          <.icon name="hero-play" class="w-4 h-4 text-slate-400" /> Enable
                        <% end %>
                      </button>
                    <% end %>
                    <.link
                      navigate={~p"/jobs/#{@job.id}/edit"}
                      class="block px-4 py-2 text-sm text-slate-700 hover:bg-slate-50 flex items-center gap-2"
                    >
                      <.icon name="hero-pencil" class="w-4 h-4 text-slate-400" /> Edit
                    </.link>
                    <button
                      type="button"
                      phx-click="toggle_mute"
                      class="w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50 flex items-center gap-2 cursor-pointer"
                    >
                      <%= if @job.muted do %>
                        <.icon name="hero-bell" class="w-4 h-4 text-slate-400" /> Unmute
                      <% else %>
                        <.icon name="hero-bell-slash" class="w-4 h-4 text-slate-400" /> Mute
                      <% end %>
                    </button>
                    <button
                      type="button"
                      phx-click="clone"
                      class="w-full text-left px-4 py-2 text-sm text-slate-700 hover:bg-slate-50 flex items-center gap-2 cursor-pointer"
                    >
                      <.icon name="hero-document-duplicate" class="w-4 h-4 text-slate-400" /> Clone
                    </button>
                    <div class="border-t border-slate-100 my-1"></div>
                    <button
                      type="button"
                      phx-click="delete"
                      data-confirm="Are you sure you want to delete this job? This cannot be undone."
                      class="w-full text-left px-4 py-2 text-sm text-red-600 hover:bg-red-50 flex items-center gap-2 cursor-pointer"
                    >
                      <.icon name="hero-trash" class="w-4 h-4" /> Delete
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <div class="p-4 sm:p-6 space-y-6">
          <%= if @test_result do %>
            <.test_result_panel test_result={@test_result} />
          <% end %>
          <!-- Webhook Details -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Webhook</h3>
            <div class="bg-white/30 rounded-xl p-3 sm:p-4 space-y-3">
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
            <div class="bg-white/30 rounded-xl p-3 sm:p-4">
              <%= if @job.schedule_type == "cron" do %>
                <div class="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3">
                  <span class="font-mono text-base sm:text-lg bg-slate-200 px-3 py-1 rounded w-fit">
                    {@job.cron_expression}
                  </span>
                  <span class="text-slate-600">{Prikke.Cron.describe(@job.cron_expression)}</span>
                </div>
                <p class="text-sm text-slate-500 mt-2">Timezone: {@job.timezone}</p>
              <% else %>
                <div>
                  <span class="text-slate-900 font-medium">One-time execution</span>
                  <p class="text-slate-600 mt-1">
                    Scheduled for
                    <.local_time id="job-scheduled" datetime={@job.scheduled_at} format="full" />
                  </p>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Settings -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Settings</h3>
            <div class="bg-white/30 rounded-xl p-3 sm:p-4 grid grid-cols-2 gap-4">
              <div>
                <span class="text-xs text-slate-500 uppercase">Timeout</span>
                <p class="text-slate-900">{format_timeout(@job.timeout_ms)}</p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Retry Attempts</span>
                <p class="text-slate-900">{@job.retry_attempts}</p>
              </div>
              <%= if @job.callback_url do %>
                <div class="col-span-2">
                  <span class="text-xs text-slate-500 uppercase">Callback URL</span>
                  <p class="text-slate-900 font-mono text-sm break-all">{@job.callback_url}</p>
                </div>
              <% end %>
              <%= if @job.expected_status_codes do %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Expected Status Codes</span>
                  <p class="text-slate-900 font-mono text-sm">{@job.expected_status_codes}</p>
                </div>
              <% end %>
              <%= if @job.expected_body_pattern do %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Response Body Contains</span>
                  <p class="text-slate-900 font-mono text-sm">"{@job.expected_body_pattern}"</p>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Stats (24h) -->
          <%= if @stats.total > 0 do %>
            <div>
              <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">
                Last 24 Hours
              </h3>
              <div class="bg-white/30 rounded-xl p-3 sm:p-4 grid grid-cols-2 sm:grid-cols-4 gap-4">
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
          
    <!-- Execution History -->
          <div>
            <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-3">
              <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide">
                Execution History
                <span class="text-slate-400 font-normal normal-case">
                  ({@total_count} total)
                </span>
              </h3>
              <form phx-change="filter" class="flex items-center gap-2">
                <label for="status-filter" class="text-sm text-slate-500">Filter:</label>
                <select
                  name="status"
                  id="status-filter"
                  class="text-sm border-slate-200 rounded-md py-1 pl-2 pr-8 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <option value="" selected={@status_filter == nil}>All</option>
                  <option value="success" selected={@status_filter == "success"}>Success</option>
                  <option value="failed" selected={@status_filter == "failed"}>Failed</option>
                  <option value="timeout" selected={@status_filter == "timeout"}>Timeout</option>
                  <option value="pending" selected={@status_filter == "pending"}>Pending</option>
                  <option value="running" selected={@status_filter == "running"}>Running</option>
                </select>
              </form>
            </div>
            <%= if @executions == [] do %>
              <div class="bg-white/30 rounded-xl p-6 sm:p-8 text-center text-slate-500">
                <%= if @status_filter do %>
                  No executions matching this filter.
                <% else %>
                  No executions yet. This job will run according to its schedule.
                <% end %>
              </div>
            <% else %>
              <div class="bg-white/30 rounded-xl overflow-hidden divide-y divide-white/30">
                <%= for exec <- @executions do %>
                  <.link
                    navigate={~p"/jobs/#{@job.id}/executions/#{exec.id}"}
                    class="block px-4 py-3 hover:bg-slate-100 transition-colors"
                  >
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-3">
                        <.status_badge status={exec.status} />
                        <span class="text-sm text-slate-600">
                          <.local_time id={"exec-#{exec.id}"} datetime={exec.scheduled_for} />
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
              <%= if length(@executions) < @total_count do %>
                <div class="mt-4 text-center">
                  <button
                    type="button"
                    phx-click="load_more"
                    class="px-4 py-2 text-sm font-medium text-slate-600 bg-white border border-slate-200 rounded-md hover:bg-white/50 transition-colors"
                  >
                    Load more
                    <span class="text-slate-400">
                      (showing {length(@executions)} of {@total_count})
                    </span>
                  </button>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
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
    """
  end

  defp test_result_panel(assigns) do
    ~H"""
    <div id="test-result-panel" class="rounded-lg border overflow-hidden">
      <%= case @test_result do %>
        <% {:ok, result} -> %>
          <div class={[
            "px-4 py-3 flex items-center justify-between",
            result.status >= 200 and result.status < 300 && "bg-emerald-50 border-emerald-200",
            (result.status < 200 or result.status >= 300) && "bg-red-50 border-red-200"
          ]}>
            <div class="flex items-center gap-3">
              <%= if result.status >= 200 and result.status < 300 do %>
                <.icon name="hero-check-circle" class="w-5 h-5 text-emerald-600" />
              <% else %>
                <.icon name="hero-x-circle" class="w-5 h-5 text-red-600" />
              <% end %>
              <span class="font-mono text-sm font-medium">HTTP {result.status}</span>
              <span class="text-sm text-slate-500">{result.duration_ms}ms</span>
            </div>
            <button
              type="button"
              phx-click="dismiss_test_result"
              class="text-slate-400 hover:text-slate-600 cursor-pointer"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
          <%= if result.body && result.body != "" do %>
            <div class="px-4 py-3 bg-white/50 border-t border-slate-100">
              <pre class="text-xs font-mono text-slate-700 whitespace-pre-wrap break-all max-h-48 overflow-y-auto"><%= result.body %></pre>
            </div>
          <% end %>
        <% {:error, message} -> %>
          <div class="px-4 py-3 bg-red-50 border-red-200 flex items-center justify-between">
            <div class="flex items-center gap-3">
              <.icon name="hero-x-circle" class="w-5 h-5 text-red-600" />
              <span class="text-sm text-red-700">{message}</span>
            </div>
            <button
              type="button"
              phx-click="dismiss_test_result"
              class="text-slate-400 hover:text-slate-600 cursor-pointer"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
      <% end %>
    </div>
    """
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

  defp truncate(nil, _), do: nil
  defp truncate(string, max) when byte_size(string) <= max, do: string
  defp truncate(string, max), do: String.slice(string, 0, max) <> "..."
end
