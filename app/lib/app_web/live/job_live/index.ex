defmodule PrikkeWeb.JobLive.Index do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs
  alias Prikke.Executions

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      if connected?(socket) do
        Jobs.subscribe_jobs(org)
        Executions.subscribe_organization_executions(org.id)
      end

      jobs = Jobs.list_jobs(org)
      job_ids = Enum.map(jobs, & &1.id)
      latest_statuses = Executions.get_latest_statuses(job_ids)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Jobs")
       |> assign(:jobs, jobs)
       |> assign(:latest_statuses, latest_statuses)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_info({:created, job}, socket) do
    {:noreply,
     socket
     |> update(:jobs, fn jobs -> [job | jobs] end)
     |> refresh_latest_statuses()}
  end

  def handle_info({:updated, job}, socket) do
    {:noreply,
     socket
     |> update(:jobs, fn jobs ->
       Enum.map(jobs, fn j -> if j.id == job.id, do: job, else: j end)
     end)
     |> refresh_latest_statuses()}
  end

  def handle_info({:deleted, job}, socket) do
    {:noreply,
     socket
     |> update(:jobs, fn jobs ->
       Enum.reject(jobs, fn j -> j.id == job.id end)
     end)
     |> update(:latest_statuses, fn statuses -> Map.delete(statuses, job.id) end)}
  end

  def handle_info({:execution_updated, execution}, socket) do
    # Update the status for this job
    job_id = execution.job_id

    {:noreply,
     socket
     |> update(:latest_statuses, fn statuses ->
       Map.put(statuses, job_id, %{status: execution.status, attempt: execution.attempt})
     end)}
  end

  defp refresh_latest_statuses(socket) do
    job_ids = Enum.map(socket.assigns.jobs, & &1.id)
    assign(socket, :latest_statuses, Executions.get_latest_statuses(job_ids))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    job = Jobs.get_job!(socket.assigns.organization, id)

    {:ok, _} =
      Jobs.delete_job(socket.assigns.organization, job, scope: socket.assigns.current_scope)

    {:noreply, put_flash(socket, :info, "Job deleted successfully")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    job = Jobs.get_job!(socket.assigns.organization, id)

    {:ok, _} =
      Jobs.toggle_job(socket.assigns.organization, job, scope: socket.assigns.current_scope)

    {:noreply, socket}
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-6 sm:py-8 px-4">
      <div class="mb-4">
        <.link
          navigate={~p"/dashboard"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Dashboard
        </.link>
      </div>

      <div class="flex justify-between items-center mb-6 sm:mb-8">
        <div>
          <h1 class="text-xl sm:text-2xl font-bold text-slate-900">Jobs</h1>
          <p class="text-slate-500 mt-1 text-sm sm:text-base">{@organization.name}</p>
        </div>
        <div class="flex gap-2">
          <.link
            navigate={~p"/queue"}
            class="font-medium text-slate-700 bg-slate-100 hover:bg-slate-200 px-3 sm:px-4 py-2 rounded-md transition-colors text-sm sm:text-base flex items-center gap-1.5"
          >
            <.icon name="hero-bolt" class="w-4 h-4" /> Queue
          </.link>
          <.link
            navigate={~p"/jobs/new"}
            class="font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-3 sm:px-4 py-2 rounded-md transition-colors text-sm sm:text-base"
          >
            New Job
          </.link>
        </div>
      </div>

      <%= if @jobs == [] do %>
        <div class="glass-card rounded-2xl p-8 sm:p-12 text-center">
          <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-clock" class="w-6 h-6 text-slate-400" />
          </div>
          <h3 class="text-lg font-medium text-slate-900 mb-2">No jobs yet</h3>
          <p class="text-slate-500 mb-6">Create your first scheduled job to get started.</p>
          <.link navigate={~p"/jobs/new"} class="text-emerald-600 font-medium hover:underline">
            Create a job →
          </.link>
        </div>
      <% else %>
        <div class="glass-card rounded-2xl divide-y divide-white/30">
          <%= for job <- @jobs do %>
            <div class="px-4 sm:px-6 py-4">
              <div class="flex items-start sm:items-center justify-between gap-3">
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 sm:gap-3 flex-wrap">
                    <.execution_status_dot status={get_status(@latest_statuses[job.id])} />
                    <.link
                      navigate={~p"/jobs/#{job.id}"}
                      class="font-medium text-slate-900 hover:text-emerald-600 break-all sm:truncate"
                    >
                      {job.name}
                    </.link>
                    <%= if job.muted do %>
                      <span title="Notifications muted">
                        <.icon name="hero-bell-slash" class="w-4 h-4 text-slate-400" />
                      </span>
                    <% end %>
                    <.job_status_badge job={job} latest_info={@latest_statuses[job.id]} />
                  </div>
                  <div class="text-sm text-slate-500 mt-1 flex items-center gap-2">
                    <span class="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded shrink-0">
                      {job.method}
                    </span>
                    <span class="truncate text-xs sm:text-sm">{job.url}</span>
                  </div>
                  <div class="text-xs sm:text-sm text-slate-400 mt-1">
                    <%= if job.schedule_type == "cron" do %>
                      <span class="font-mono">{job.cron_expression}</span>
                      <span class="text-slate-500 ml-1">
                        · {Prikke.Cron.describe(job.cron_expression)}
                      </span>
                    <% else %>
                      <span class="hidden sm:inline">One-time: </span>
                      <.local_time id={"job-#{job.id}-scheduled"} datetime={job.scheduled_at} />
                    <% end %>
                  </div>
                </div>
                <div class="flex items-center gap-2 sm:gap-3 shrink-0">
                  <%= if job.schedule_type == "cron" do %>
                    <button
                      type="button"
                      phx-click="toggle"
                      phx-value-id={job.id}
                      class={[
                        "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:ring-offset-2",
                        job.enabled && "bg-emerald-600",
                        !job.enabled && "bg-slate-200"
                      ]}
                    >
                      <span class={[
                        "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                        job.enabled && "translate-x-5",
                        !job.enabled && "translate-x-0"
                      ]}>
                      </span>
                    </button>
                  <% end %>
                  <.link
                    navigate={~p"/jobs/#{job.id}/edit"}
                    class="text-slate-400 hover:text-slate-600 p-1"
                  >
                    <.icon name="hero-pencil-square" class="w-5 h-5" />
                  </.link>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={job.id}
                    data-confirm="Are you sure you want to delete this job?"
                    class="text-slate-400 hover:text-red-600 p-1"
                  >
                    <.icon name="hero-trash" class="w-5 h-5" />
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
