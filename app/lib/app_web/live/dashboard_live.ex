defmodule PrikkeWeb.DashboardLive do
  use PrikkeWeb, :live_view

  alias Prikke.Accounts
  alias Prikke.Jobs

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

    # Subscribe to job updates if we have an organization
    if current_org && connected?(socket) do
      Jobs.subscribe_jobs(current_org)
    end

    socket =
      socket
      |> assign(:current_organization, current_org)
      |> assign(:organizations, organizations)
      |> assign(:pending_invites_count, length(pending_invites))
      |> assign(:stats, load_stats(current_org))
      |> assign(:recent_jobs, load_recent_jobs(current_org))

    {:ok, socket}
  end

  @impl true
  def handle_info({:created, _job}, socket) do
    org = socket.assigns.current_organization
    {:noreply,
     socket
     |> assign(:stats, load_stats(org))
     |> assign(:recent_jobs, load_recent_jobs(org))}
  end

  def handle_info({:updated, _job}, socket) do
    org = socket.assigns.current_organization
    {:noreply,
     socket
     |> assign(:stats, load_stats(org))
     |> assign(:recent_jobs, load_recent_jobs(org))}
  end

  def handle_info({:deleted, _job}, socket) do
    org = socket.assigns.current_organization
    {:noreply,
     socket
     |> assign(:stats, load_stats(org))
     |> assign(:recent_jobs, load_recent_jobs(org))}
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
              <span class="text-slate-500"><%= @current_organization.name %></span>
              <span class="text-xs font-medium text-slate-400 bg-slate-100 px-2 py-0.5 rounded">
                <%= String.capitalize(@current_organization.tier) %>
              </span>
              <%= if length(@organizations) > 1 do %>
                <span class="text-slate-300">·</span>
                <a href={~p"/organizations"} class="text-sm text-emerald-600 hover:underline">Switch</a>
              <% end %>
            </div>
          <% else %>
            <p class="text-slate-500 mt-1">
              <a href={~p"/organizations/new"} class="text-emerald-600 hover:underline">Create an organization</a> to get started
            </p>
          <% end %>
        </div>
        <%= if @current_organization do %>
          <a href={~p"/organizations/settings"} class="text-sm text-slate-500 hover:text-slate-700">
            Org Settings
          </a>
        <% end %>
      </div>

      <%= if @current_organization do %>
        <!-- Quick Stats -->
        <div class="grid grid-cols-3 gap-4 mb-8">
          <.link navigate={~p"/jobs"} class="bg-white border border-slate-200 rounded-lg p-6 hover:border-slate-300 transition-colors">
            <div class="text-sm font-medium text-slate-500 mb-1">Active Jobs</div>
            <div class="text-3xl font-bold text-slate-900"><%= @stats.active_jobs %></div>
          </.link>
          <div class="bg-white border border-slate-200 rounded-lg p-6">
            <div class="text-sm font-medium text-slate-500 mb-1">Executions Today</div>
            <div class="text-3xl font-bold text-slate-900"><%= @stats.executions_today %></div>
          </div>
          <div class="bg-white border border-slate-200 rounded-lg p-6">
            <div class="text-sm font-medium text-slate-500 mb-1">Success Rate</div>
            <div class="text-3xl font-bold text-emerald-500"><%= @stats.success_rate %></div>
          </div>
        </div>

        <!-- Jobs Section -->
        <div class="bg-white border border-slate-200 rounded-lg">
          <div class="px-6 py-4 border-b border-slate-200 flex justify-between items-center">
            <h2 class="text-lg font-semibold text-slate-900">Jobs</h2>
            <.link
              navigate={~p"/jobs/new"}
              class="text-sm font-medium text-white bg-emerald-500 hover:bg-emerald-600 px-4 py-2 rounded-md transition-colors no-underline"
            >
              New Job
            </.link>
          </div>
          <%= if @recent_jobs == [] do %>
            <div class="p-12 text-center">
              <div class="w-12 h-12 bg-slate-100 rounded-full flex items-center justify-center mx-auto mb-4">
                <svg class="w-6 h-6 text-slate-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M12 6v6l4 2m6-2a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
              </div>
              <h3 class="text-lg font-medium text-slate-900 mb-1">No jobs yet</h3>
              <p class="text-slate-500 mb-4">Create your first scheduled job to get started.</p>
              <.link navigate={~p"/jobs/new"} class="text-emerald-600 font-medium hover:underline">Create a job →</.link>
            </div>
          <% else %>
            <div class="divide-y divide-slate-200">
              <%= for job <- @recent_jobs do %>
                <.link navigate={~p"/jobs/#{job.id}"} class="block px-6 py-4 hover:bg-slate-50 transition-colors">
                  <div class="flex items-center justify-between">
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <span class="font-medium text-slate-900 truncate"><%= job.name %></span>
                        <span class={[
                          "text-xs font-medium px-2 py-0.5 rounded",
                          job.enabled && "bg-emerald-100 text-emerald-700",
                          !job.enabled && "bg-slate-100 text-slate-500"
                        ]}>
                          <%= if job.enabled, do: "Active", else: "Paused" %>
                        </span>
                      </div>
                      <div class="text-sm text-slate-500 mt-0.5 flex items-center gap-2">
                        <span class="font-mono text-xs"><%= job.method %></span>
                        <span class="truncate"><%= job.url %></span>
                      </div>
                    </div>
                    <div class="text-xs text-slate-400 ml-4">
                      <%= if job.schedule_type == "cron" do %>
                        <span class="font-mono"><%= job.cron_expression %></span>
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
                  View all <%= @stats.total_jobs %> jobs →
                </.link>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Recent Executions -->
        <div class="bg-white border border-slate-200 rounded-lg mt-6">
          <div class="px-6 py-4 border-b border-slate-200">
            <h2 class="text-lg font-semibold text-slate-900">Recent Executions</h2>
          </div>
          <div class="p-8 text-center text-slate-500">
            No executions yet. Jobs will appear here once they run.
          </div>
        </div>
      <% else %>
        <!-- No organization state -->
        <div class="bg-white border border-slate-200 rounded-lg p-12 text-center">
          <div class="w-12 h-12 bg-emerald-100 rounded-full flex items-center justify-center mx-auto mb-4">
            <svg class="w-6 h-6 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4" />
            </svg>
          </div>
          <h3 class="text-lg font-medium text-slate-900 mb-1">Create your first organization</h3>
          <p class="text-slate-500 mb-6">Organizations help you manage jobs and team members.</p>
          <a href={~p"/organizations/new"} class="inline-block px-6 py-3 bg-emerald-500 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors no-underline">
            Create Organization
          </a>
        </div>
      <% end %>
    </div>

    <!-- Footer -->
    <footer class="border-t border-slate-200 mt-12">
      <div class="max-w-4xl mx-auto px-4 py-6">
        <div class="flex justify-between items-center text-sm text-slate-500">
          <div class="flex gap-6">
            <a href="/docs" class="hover:text-slate-700">Docs</a>
            <a href="/docs/api" class="hover:text-slate-700">API</a>
            <a href="/docs/cron" class="hover:text-slate-700">Cron</a>
            <a href="/docs/webhooks" class="hover:text-slate-700">Webhooks</a>
          </div>
          <div>
            <a href="mailto:gaute.magnussen@gmail.com" class="hover:text-slate-700">Contact</a>
          </div>
        </div>
      </div>
    </footer>
    """
  end

  defp load_stats(nil), do: %{active_jobs: 0, total_jobs: 0, executions_today: 0, success_rate: "—"}

  defp load_stats(organization) do
    %{
      active_jobs: Jobs.count_enabled_jobs(organization),
      total_jobs: Jobs.count_jobs(organization),
      executions_today: 0,
      success_rate: "—"
    }
  end

  defp load_recent_jobs(nil), do: []

  defp load_recent_jobs(organization) do
    organization
    |> Jobs.list_jobs()
    |> Enum.take(5)
  end
end
