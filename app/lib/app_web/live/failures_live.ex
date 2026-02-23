defmodule PrikkeWeb.FailuresLive do
  use PrikkeWeb, :live_view

  alias Prikke.Tasks
  alias Prikke.Executions

  @per_page 30

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      if connected?(socket) do
        Executions.subscribe_organization_executions(org.id)
      end

      queues = Tasks.list_queues(org)
      executions = Executions.list_failed_executions(org, limit: @per_page)
      total_count = Executions.count_failed_executions(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Failures")
       |> assign(:executions, executions)
       |> assign(:total_count, total_count)
       |> assign(:queues, queues)
       |> assign(:queue_filter, nil)
       |> assign(:selected, MapSet.new())}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_info({:execution_updated, _execution}, socket) do
    {:noreply, refetch(socket)}
  end

  @impl true
  def handle_event("filter", %{"queue" => queue}, socket) do
    queue_filter = if queue == "", do: nil, else: queue
    org = socket.assigns.organization
    opts = filter_opts(queue_filter)

    executions = Executions.list_failed_executions(org, [{:limit, @per_page} | opts])
    total_count = Executions.count_failed_executions(org, opts)

    {:noreply,
     socket
     |> assign(:queue_filter, queue_filter)
     |> assign(:executions, executions)
     |> assign(:total_count, total_count)
     |> assign(:selected, MapSet.new())}
  end

  def handle_event("load_more", _, socket) do
    org = socket.assigns.organization
    opts = filter_opts(socket.assigns.queue_filter)
    current_count = length(socket.assigns.executions)

    more =
      Executions.list_failed_executions(org, [
        {:limit, @per_page},
        {:offset, current_count} | opts
      ])

    {:noreply, assign(socket, :executions, socket.assigns.executions ++ more)}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    execution = Executions.get_execution_for_org(socket.assigns.organization, id)

    if execution do
      case Executions.retry_execution(execution) do
        {:ok, _new_exec} ->
          {:noreply,
           socket
           |> put_flash(:info, "Retry queued")
           |> refetch()}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to retry")}
      end
    else
      {:noreply, put_flash(socket, :error, "Execution not found")}
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, id) do
        MapSet.delete(socket.assigns.selected, id)
      else
        MapSet.put(socket.assigns.selected, id)
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _, socket) do
    all_ids = Enum.map(socket.assigns.executions, & &1.id) |> MapSet.new()
    {:noreply, assign(socket, :selected, all_ids)}
  end

  def handle_event("select_none", _, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("bulk_retry", _, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    if ids == [] do
      {:noreply, put_flash(socket, :error, "No executions selected")}
    else
      {:ok, count} = Executions.bulk_retry_executions(socket.assigns.organization, ids)

      {:noreply,
       socket
       |> put_flash(:info, "#{count} retries queued")
       |> assign(:selected, MapSet.new())
       |> refetch()}
    end
  end

  defp refetch(socket) do
    org = socket.assigns.organization
    opts = filter_opts(socket.assigns.queue_filter)
    current_loaded = max(length(socket.assigns.executions), @per_page)

    executions = Executions.list_failed_executions(org, [{:limit, current_loaded} | opts])
    total_count = Executions.count_failed_executions(org, opts)

    socket
    |> assign(:executions, executions)
    |> assign(:total_count, total_count)
    |> assign(:queues, Tasks.list_queues(org))
  end

  defp filter_opts(nil), do: []
  defp filter_opts(queue), do: [queue: queue]

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

  defp status_class("failed"), do: "bg-red-100 text-red-700"
  defp status_class("timeout"), do: "bg-amber-100 text-amber-700"
  defp status_class(_), do: "bg-slate-100 text-slate-600"

  defp format_duration(nil), do: "-"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
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
          <h1 class="text-xl sm:text-2xl font-bold text-slate-900">Failures</h1>
          <p class="text-slate-500 mt-1 text-sm">
            Failed and timed-out executions across all tasks
          </p>
        </div>
        <%= if MapSet.size(@selected) > 0 do %>
          <button
            type="button"
            phx-click="bulk_retry"
            class="text-sm font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-3 sm:px-4 py-2 rounded-md transition-colors whitespace-nowrap"
          >
            Retry selected ({MapSet.size(@selected)})
          </button>
        <% end %>
      </div>

      <div class="mb-4" id="failure-filters">
        <form phx-change="filter" class="flex flex-wrap gap-2 items-center">
          <%= if @queues != [] do %>
            <select
              name="queue"
              id="failure-queue-filter"
              class="text-sm border-slate-200 rounded-lg px-3 py-1.5 text-slate-700 focus:ring-emerald-500 focus:border-emerald-500"
            >
              <option value="" selected={@queue_filter == nil}>All queues</option>
              <%= for queue <- @queues do %>
                <option value={queue} selected={@queue_filter == queue}>{queue}</option>
              <% end %>
            </select>
          <% end %>
          <%= if length(@executions) > 0 do %>
            <div class="flex gap-2 ml-auto">
              <button
                type="button"
                phx-click="select_all"
                class="text-xs text-slate-500 hover:text-slate-700"
              >
                Select all
              </button>
              <button
                type="button"
                phx-click="select_none"
                class="text-xs text-slate-500 hover:text-slate-700"
              >
                Clear
              </button>
            </div>
          <% end %>
        </form>
      </div>

      <%= if @executions == [] do %>
        <div class="glass-card rounded-2xl p-8 sm:p-12 text-center">
          <div class="w-12 h-12 bg-emerald-100 rounded-full flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-check-circle" class="w-6 h-6 text-emerald-600" />
          </div>
          <h3 class="text-lg font-medium text-slate-900 mb-2">No failures</h3>
          <p class="text-slate-500">All executions are running smoothly.</p>
        </div>
      <% else %>
        <div class="glass-card rounded-2xl divide-y divide-slate-200/60">
          <%= for execution <- @executions do %>
            <div class="px-4 sm:px-6 py-4 flex items-start gap-3">
              <label class="flex items-center pt-1 cursor-pointer">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@selected, execution.id)}
                  phx-click="toggle_select"
                  phx-value-id={execution.id}
                  class="rounded border-slate-300 text-emerald-600 focus:ring-emerald-500"
                />
              </label>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class={[
                    "text-xs font-medium px-2 py-0.5 rounded",
                    status_class(execution.status)
                  ]}>
                    {execution.status}
                  </span>
                  <%= if execution.task do %>
                    <.link
                      navigate={~p"/tasks/#{execution.task_id}"}
                      class="font-medium text-slate-900 hover:text-emerald-600 truncate"
                    >
                      {execution.task.name}
                    </.link>
                  <% else %>
                    <span class="text-slate-400 italic">Deleted task</span>
                  <% end %>
                  <%= if execution.queue do %>
                    <span class="text-xs font-medium px-1.5 py-0.5 rounded bg-indigo-50 text-indigo-600 border border-indigo-100">
                      {execution.queue}
                    </span>
                  <% end %>
                </div>
                <div class="text-sm text-slate-500 mt-1 flex items-center gap-2 flex-wrap">
                  <%= if execution.task do %>
                    <span class="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded shrink-0">
                      {execution.task.method}
                    </span>
                    <span class="truncate text-xs">{execution.task.url}</span>
                  <% end %>
                </div>
                <%= if execution.error_message do %>
                  <p class="text-xs text-red-600 mt-1 truncate">{execution.error_message}</p>
                <% end %>
                <div class="text-xs text-slate-400 mt-1 flex items-center gap-1.5">
                  <.local_time
                    id={"failure-#{execution.id}-time"}
                    datetime={execution.scheduled_for}
                  />
                  <%= if execution.duration_ms do %>
                    <span class="text-slate-300">·</span>
                    <span>{format_duration(execution.duration_ms)}</span>
                  <% end %>
                  <%= if execution.status_code do %>
                    <span class="text-slate-300">·</span>
                    <span>HTTP {execution.status_code}</span>
                  <% end %>
                </div>
              </div>
              <button
                type="button"
                phx-click="retry"
                phx-value-id={execution.id}
                class="text-sm font-medium text-emerald-600 hover:text-emerald-700 px-2 py-1 rounded hover:bg-emerald-50 transition-colors shrink-0"
                title="Retry this execution"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4" />
              </button>
            </div>
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
    </Layouts.app>
    """
  end
end
