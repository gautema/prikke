defmodule PrikkeWeb.JobLive.Show do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      job = Jobs.get_job!(org, id)
      if connected?(socket), do: Jobs.subscribe_jobs(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:job, job)
       |> assign(:page_title, job.name)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, _params) do
    assign(socket, :page_title, "Edit: #{socket.assigns.job.name}")
  end

  defp apply_action(socket, :show, _params) do
    assign(socket, :page_title, socket.assigns.job.name)
  end

  @impl true
  def handle_info({:updated, job}, socket) do
    if job.id == socket.assigns.job.id do
      {:noreply, assign(socket, :job, job)}
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
          <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
          </svg>
          Back to Jobs
        </.link>
      </div>

      <div class="bg-white border border-slate-200 rounded-lg">
        <div class="px-6 py-4 border-b border-slate-200 flex justify-between items-start">
          <div>
            <div class="flex items-center gap-3">
              <h1 class="text-xl font-bold text-slate-900"><%= @job.name %></h1>
              <span class={[
                "text-xs font-medium px-2 py-0.5 rounded",
                @job.enabled && "bg-emerald-100 text-emerald-700",
                !@job.enabled && "bg-slate-100 text-slate-500"
              ]}>
                <%= if @job.enabled, do: "Active", else: "Paused" %>
              </span>
            </div>
            <p class="text-sm text-slate-500 mt-1">Created <%= Calendar.strftime(@job.inserted_at, "%b %d, %Y") %></p>
          </div>
          <div class="flex items-center gap-2">
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

          <!-- Recent Executions Placeholder -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Recent Executions</h3>
            <div class="bg-slate-50 rounded-lg p-8 text-center text-slate-500">
              No executions yet. This job will run according to its schedule.
            </div>
          </div>
        </div>
      </div>
    </div>

    <.modal :if={@live_action == :edit} id="job-modal" show on_cancel={JS.patch(~p"/jobs/#{@job.id}")}>
      <.live_component
        module={PrikkeWeb.JobLive.FormComponent}
        id={@job.id}
        title="Edit Job"
        action={:edit}
        job={@job}
        organization={@organization}
        patch={~p"/jobs/#{@job.id}"}
      />
    </.modal>
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
end
