defmodule PrikkeWeb.TaskLive.Index do
  use PrikkeWeb, :live_view

  alias Prikke.Tasks
  alias Prikke.Executions

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      if connected?(socket) do
        Tasks.subscribe_tasks(org)
        Executions.subscribe_organization_executions(org.id)
      end

      tasks = Tasks.list_tasks(org)
      task_ids = Enum.map(tasks, & &1.id)
      latest_statuses = Executions.get_latest_statuses(task_ids)
      task_run_histories = Executions.get_recent_statuses_for_tasks(task_ids, 20)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Tasks")
       |> assign(:tasks, tasks)
       |> assign(:latest_statuses, latest_statuses)
       |> assign(:task_run_histories, task_run_histories)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_info({:created, task}, socket) do
    {:noreply,
     socket
     |> update(:tasks, fn tasks -> [task | tasks] end)
     |> refresh_latest_statuses()}
  end

  def handle_info({:updated, task}, socket) do
    {:noreply,
     socket
     |> update(:tasks, fn tasks ->
       Enum.map(tasks, fn t -> if t.id == task.id, do: task, else: t end)
     end)
     |> refresh_latest_statuses()}
  end

  def handle_info({:deleted, task}, socket) do
    {:noreply,
     socket
     |> update(:tasks, fn tasks ->
       Enum.reject(tasks, fn t -> t.id == task.id end)
     end)
     |> update(:latest_statuses, fn statuses -> Map.delete(statuses, task.id) end)}
  end

  def handle_info({:execution_updated, _execution}, socket) do
    {:noreply, refresh_latest_statuses(socket)}
  end

  defp refresh_latest_statuses(socket) do
    task_ids = Enum.map(socket.assigns.tasks, & &1.id)

    socket
    |> assign(:latest_statuses, Executions.get_latest_statuses(task_ids))
    |> assign(:task_run_histories, Executions.get_recent_statuses_for_tasks(task_ids, 20))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.organization, id)

    {:ok, _} =
      Tasks.delete_task(socket.assigns.organization, task, scope: socket.assigns.current_scope)

    {:noreply, put_flash(socket, :info, "Task deleted successfully")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.organization, id)

    {:ok, _} =
      Tasks.toggle_task(socket.assigns.organization, task, scope: socket.assigns.current_scope)

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

  defp task_completed?(task, latest_info) do
    task.schedule_type == "once" and is_nil(task.next_run_at) and
      get_status(latest_info) == "success"
  end

  defp task_status_badge(assigns) do
    status = get_status(assigns.latest_info)
    attempt = get_attempt(assigns.latest_info)
    assigns = assign(assigns, :status, status)
    assigns = assign(assigns, :attempt, attempt)

    ~H"""
    <%= cond do %>
      <% task_completed?(@task, @latest_info) -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-slate-100 text-slate-600">
          Completed
        </span>
      <% @task.schedule_type == "once" and @status in ["failed", "timeout"] -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-red-100 text-red-700">Failed</span>
      <% @task.schedule_type == "once" and @status in ["pending", "running"] and @attempt > 1 -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-amber-100 text-amber-700">
          Retrying ({@attempt}/{@task.retry_attempts})
        </span>
      <% @task.schedule_type == "once" and @status in ["pending", "running"] -> %>
        <span class="text-xs font-medium px-2 py-0.5 rounded bg-blue-100 text-blue-700">Running</span>
      <% @task.enabled -> %>
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

  defp run_history_line(%{statuses: []} = assigns) do
    ~H"""
    <div class="flex items-center gap-0.5 mt-2 pl-5">
      <span class="text-xs text-slate-300">No runs yet</span>
    </div>
    """
  end

  defp run_history_line(assigns) do
    assigns = assign(assigns, :reversed, Enum.reverse(assigns.statuses))
    total = length(assigns.statuses)
    success = Enum.count(assigns.statuses, &(&1 == "success"))
    rate = if total > 0, do: round(success / total * 100), else: 0
    assigns = assign(assigns, :rate, rate)
    assigns = assign(assigns, :total, total)

    ~H"""
    <div class="flex items-center gap-0.5 mt-2 pl-5">
      <div class="flex items-center gap-px flex-1">
        <%= for status <- @reversed do %>
          <div
            class={["h-3 flex-1 first:rounded-l-sm last:rounded-r-sm", run_status_color(status)]}
            title={status}
          />
        <% end %>
      </div>
      <span class="text-xs text-slate-400 ml-2 shrink-0 tabular-nums w-16 text-right">
        {@rate}% of {@total}
      </span>
    </div>
    """
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp run_status_color("success"), do: "bg-emerald-500"
  defp run_status_color("failed"), do: "bg-red-500"
  defp run_status_color("timeout"), do: "bg-amber-500"
  defp run_status_color("missed"), do: "bg-orange-400"
  defp run_status_color(_), do: "bg-slate-200"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-6 sm:py-8 px-2 sm:px-4">
      <div class="mb-4">
        <.link
          navigate={~p"/dashboard"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Dashboard
        </.link>
      </div>

      <div class="flex justify-between items-center mb-6 sm:mb-8 pl-1 sm:pl-0">
        <div>
          <h1 class="text-xl sm:text-2xl font-bold text-slate-900">Tasks</h1>
          <p class="text-slate-500 mt-1 text-sm sm:text-base">{@organization.name}</p>
        </div>
        <div class="flex gap-2">
          <.link
            navigate={~p"/tasks/new"}
            class="font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-3 sm:px-4 py-2 rounded-md transition-colors text-sm sm:text-base"
          >
            New Task
          </.link>
        </div>
      </div>

      <%= if @tasks == [] do %>
        <div class="glass-card rounded-2xl p-8 sm:p-12 text-center">
          <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-clock" class="w-6 h-6 text-slate-400" />
          </div>
          <h3 class="text-lg font-medium text-slate-900 mb-2">No tasks yet</h3>
          <p class="text-slate-500 mb-6">Create your first scheduled task to get started.</p>
          <.link navigate={~p"/tasks/new"} class="text-emerald-600 font-medium hover:underline">
            Create a task →
          </.link>
        </div>
      <% else %>
        <div class="glass-card rounded-2xl divide-y divide-slate-200/60">
          <%= for task <- @tasks do %>
            <div class="px-4 sm:px-6 py-5">
              <div class="flex items-start sm:items-center justify-between gap-3">
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 sm:gap-3 flex-wrap">
                    <.execution_status_dot status={get_status(@latest_statuses[task.id])} />
                    <.link
                      navigate={~p"/tasks/#{task.id}"}
                      class="font-medium text-slate-900 hover:text-emerald-600 break-all sm:truncate"
                    >
                      {task.name}
                    </.link>
                    <%= if task.muted do %>
                      <span title="Notifications muted">
                        <.icon name="hero-bell-slash" class="w-4 h-4 text-slate-400" />
                      </span>
                    <% end %>
                    <.task_status_badge task={task} latest_info={@latest_statuses[task.id]} />
                  </div>
                  <div class="text-sm text-slate-500 mt-1 flex items-center gap-2">
                    <span class="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded shrink-0">
                      {task.method}
                    </span>
                    <span class="truncate text-xs sm:text-sm">{task.url}</span>
                  </div>
                  <div class="text-xs sm:text-sm text-slate-400 mt-1">
                    <%= if task.schedule_type == "cron" do %>
                      <span class="font-mono">{task.cron_expression}</span>
                      <span class="text-slate-500 ml-1">
                        · {Prikke.Cron.describe(task.cron_expression)}
                      </span>
                    <% else %>
                      <span class="hidden sm:inline">One-time: </span>
                      <.local_time id={"task-#{task.id}-scheduled"} datetime={task.scheduled_at} />
                    <% end %>
                  </div>
                  <%= if @latest_statuses[task.id] do %>
                    <div class="text-xs text-slate-400 mt-1 flex items-center gap-1.5">
                      <span>Last run:</span>
                      <.local_time
                        id={"task-#{task.id}-last-run"}
                        datetime={@latest_statuses[task.id].scheduled_for}
                      />
                      <%= if @latest_statuses[task.id].duration_ms do %>
                        <span class="text-slate-300">·</span>
                        <span>{format_duration(@latest_statuses[task.id].duration_ms)}</span>
                      <% end %>
                      <span class="text-slate-300">·</span>
                      <span class={[
                        @latest_statuses[task.id].status == "success" && "text-emerald-600",
                        @latest_statuses[task.id].status == "failed" && "text-red-600",
                        @latest_statuses[task.id].status == "timeout" && "text-amber-600"
                      ]}>
                        {@latest_statuses[task.id].status}
                      </span>
                    </div>
                  <% end %>
                </div>
                <div class="flex items-center gap-2 sm:gap-3 shrink-0">
                  <%= if task.schedule_type == "cron" do %>
                    <button
                      type="button"
                      phx-click="toggle"
                      phx-value-id={task.id}
                      class={[
                        "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:ring-offset-2",
                        task.enabled && "bg-emerald-600",
                        !task.enabled && "bg-slate-200"
                      ]}
                    >
                      <span class={[
                        "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                        task.enabled && "translate-x-5",
                        !task.enabled && "translate-x-0"
                      ]}>
                      </span>
                    </button>
                  <% end %>
                  <.link
                    navigate={~p"/tasks/#{task.id}/edit"}
                    class="text-slate-400 hover:text-slate-600 p-1"
                  >
                    <.icon name="hero-pencil-square" class="w-5 h-5" />
                  </.link>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={task.id}
                    data-confirm="Are you sure you want to delete this task?"
                    class="text-slate-400 hover:text-red-600 p-1"
                  >
                    <.icon name="hero-trash" class="w-5 h-5" />
                  </button>
                </div>
              </div>
              <.run_history_line statuses={Map.get(@task_run_histories, task.id, [])} />
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
