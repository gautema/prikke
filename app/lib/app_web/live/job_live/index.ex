defmodule PrikkeWeb.JobLive.Index do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs
  alias Prikke.Jobs.Job

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      if connected?(socket), do: Jobs.subscribe_jobs(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:jobs, Jobs.list_jobs(org))}
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

  defp apply_action(socket, :edit, %{"id" => id}) do
    job = Jobs.get_job!(socket.assigns.organization, id)

    socket
    |> assign(:page_title, "Edit Job")
    |> assign(:job, job)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Job")
    |> assign(:job, %Job{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Jobs")
    |> assign(:job, nil)
  end

  @impl true
  def handle_info({:created, job}, socket) do
    {:noreply, update(socket, :jobs, fn jobs -> [job | jobs] end)}
  end

  def handle_info({:updated, job}, socket) do
    {:noreply,
     update(socket, :jobs, fn jobs ->
       Enum.map(jobs, fn j -> if j.id == job.id, do: job, else: j end)
     end)}
  end

  def handle_info({:deleted, job}, socket) do
    {:noreply,
     update(socket, :jobs, fn jobs ->
       Enum.reject(jobs, fn j -> j.id == job.id end)
     end)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    job = Jobs.get_job!(socket.assigns.organization, id)
    {:ok, _} = Jobs.delete_job(socket.assigns.organization, job)

    {:noreply, put_flash(socket, :info, "Job deleted successfully")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    job = Jobs.get_job!(socket.assigns.organization, id)
    {:ok, _} = Jobs.toggle_job(socket.assigns.organization, job)

    {:noreply, socket}
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
      <div class="flex justify-between items-center mb-8">
        <div>
          <h1 class="text-2xl font-bold text-slate-900">Jobs</h1>
          <p class="text-slate-500 mt-1"><%= @organization.name %></p>
        </div>
        <.link
          navigate={~p"/jobs/new"}
          class="text-sm font-medium text-white bg-emerald-500 hover:bg-emerald-600 px-4 py-2 rounded-md transition-colors"
        >
          New Job
        </.link>
      </div>

      <%= if @jobs == [] do %>
        <div class="bg-white border border-slate-200 rounded-lg p-12 text-center">
          <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-4">
            <svg class="w-6 h-6 text-slate-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M12 6v6l4 2m6-2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          </div>
          <h3 class="text-lg font-medium text-slate-900 mb-1">No jobs yet</h3>
          <p class="text-slate-500 mb-4">Create your first scheduled job to get started.</p>
          <.link navigate={~p"/jobs/new"} class="text-emerald-600 font-medium hover:underline">
            Create a job →
          </.link>
        </div>
      <% else %>
        <div class="bg-white border border-slate-200 rounded-lg divide-y divide-slate-200">
          <%= for job <- @jobs do %>
            <div class="px-6 py-4 flex items-center justify-between">
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-3">
                  <.link navigate={~p"/jobs/#{job.id}"} class="font-medium text-slate-900 hover:text-emerald-600 truncate">
                    <%= job.name %>
                  </.link>
                  <span class={[
                    "text-xs font-medium px-2 py-0.5 rounded",
                    job.enabled && "bg-emerald-100 text-emerald-700",
                    !job.enabled && "bg-slate-100 text-slate-500"
                  ]}>
                    <%= if job.enabled, do: "Active", else: "Paused" %>
                  </span>
                </div>
                <div class="text-sm text-slate-500 mt-1 flex items-center gap-2">
                  <span class="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded"><%= job.method %></span>
                  <span class="truncate"><%= job.url %></span>
                </div>
                <div class="text-xs text-slate-400 mt-1">
                  <%= if job.schedule_type == "cron" do %>
                    <span class="font-mono"><%= job.cron_expression %></span>
                  <% else %>
                    One-time: <%= Calendar.strftime(job.scheduled_at, "%b %d, %Y at %H:%M UTC") %>
                  <% end %>
                </div>
              </div>
              <div class="flex items-center gap-2 ml-4">
                <button
                  phx-click="toggle"
                  phx-value-id={job.id}
                  class={[
                    "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:ring-offset-2",
                    job.enabled && "bg-emerald-500",
                    !job.enabled && "bg-slate-200"
                  ]}
                >
                  <span class={[
                    "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                    job.enabled && "translate-x-5",
                    !job.enabled && "translate-x-0"
                  ]}></span>
                </button>
                <.link navigate={~p"/jobs/#{job.id}/edit"} class="text-slate-400 hover:text-slate-600 p-1">
                  <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                  </svg>
                </.link>
                <button
                  phx-click="delete"
                  phx-value-id={job.id}
                  data-confirm="Are you sure you want to delete this job?"
                  class="text-slate-400 hover:text-red-600 p-1"
                >
                  <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                  </svg>
                </button>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>

    <.modal :if={@live_action in [:new, :edit]} id="job-modal" show on_cancel={JS.patch(~p"/jobs")}>
      <.live_component
        module={PrikkeWeb.JobLive.FormComponent}
        id={@job.id || :new}
        title={@page_title}
        action={@live_action}
        job={@job}
        organization={@organization}
        patch={~p"/jobs"}
      />
    </.modal>
    """
  end
end
