defmodule PrikkeWeb.JobLive.ExecutionShow do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs
  alias Prikke.Executions

  @impl true
  def mount(%{"job_id" => job_id, "id" => execution_id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      job = Jobs.get_job!(org, job_id)
      execution = Executions.get_execution_for_job(job, execution_id)

      if execution do
        {:ok,
         socket
         |> assign(:organization, org)
         |> assign(:job, job)
         |> assign(:execution, execution)
         |> assign(:page_title, "Execution Details")}
      else
        {:ok,
         socket
         |> put_flash(:error, "Execution not found")
         |> redirect(to: ~p"/jobs/#{job_id}")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
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
    <div class="max-w-4xl mx-auto py-6 sm:py-8 px-4">
      <div class="mb-4 sm:mb-6">
        <.link navigate={~p"/jobs/#{@job.id}"} class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1">
          <.icon name="hero-chevron-left" class="w-4 h-4" />
          Back to <%= @job.name %>
        </.link>
      </div>

      <div class="bg-white border border-slate-200 rounded-lg">
        <div class="px-4 sm:px-6 py-4 border-b border-slate-200">
          <div class="flex flex-col sm:flex-row sm:justify-between sm:items-start gap-4">
            <div>
              <div class="flex items-center gap-3 flex-wrap">
                <h1 class="text-lg sm:text-xl font-bold text-slate-900">Execution Details</h1>
                <.status_badge status={@execution.status} />
              </div>
              <p class="text-sm text-slate-500 mt-1">
                Scheduled for <%= format_datetime(@execution.scheduled_for) %>
              </p>
            </div>
          </div>
        </div>

        <div class="p-4 sm:p-6 space-y-6">
          <!-- Timing -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Timing</h3>
            <div class="bg-slate-50 rounded-lg p-3 sm:p-4 grid grid-cols-2 sm:grid-cols-4 gap-4">
              <div>
                <span class="text-xs text-slate-500 uppercase">Scheduled For</span>
                <p class="text-slate-900 text-sm font-mono"><%= format_datetime(@execution.scheduled_for) %></p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Started At</span>
                <p class="text-slate-900 text-sm font-mono"><%= format_datetime(@execution.started_at) %></p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Finished At</span>
                <p class="text-slate-900 text-sm font-mono"><%= format_datetime(@execution.finished_at) %></p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Duration</span>
                <p class="text-slate-900 text-sm font-medium"><%= format_duration(@execution.duration_ms) %></p>
              </div>
            </div>
          </div>

          <!-- Request Details -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Request</h3>
            <div class="bg-slate-50 rounded-lg p-3 sm:p-4 space-y-3">
              <div class="flex items-start sm:items-center gap-2 flex-col sm:flex-row">
                <span class="font-mono text-sm bg-slate-200 px-2 py-1 rounded font-medium shrink-0"><%= @job.method %></span>
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
                  <pre class="text-xs bg-slate-100 p-2 rounded mt-1 overflow-x-auto whitespace-pre-wrap"><%= @job.body %></pre>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Response Details -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Response</h3>
            <div class="bg-slate-50 rounded-lg p-3 sm:p-4 space-y-3">
              <div class="flex items-center gap-4">
                <%= if @execution.status_code do %>
                  <div>
                    <span class="text-xs text-slate-500 uppercase">Status Code</span>
                    <p class={[
                      "text-lg font-mono font-bold",
                      status_code_color(@execution.status_code)
                    ]}>
                      <%= @execution.status_code %>
                    </p>
                  </div>
                <% end %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Attempt</span>
                  <p class="text-lg font-medium text-slate-900"><%= @execution.attempt %></p>
                </div>
              </div>

              <%= if @execution.error_message do %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Error Message</span>
                  <div class="bg-red-50 border border-red-200 rounded p-3 mt-1">
                    <p class="text-red-700 text-sm"><%= @execution.error_message %></p>
                  </div>
                </div>
              <% end %>

              <%= if @execution.response_body && @execution.response_body != "" do %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Response Body</span>
                  <pre class="text-xs bg-slate-100 p-2 rounded mt-1 overflow-x-auto whitespace-pre-wrap max-h-96 overflow-y-auto"><%= format_response_body(@execution.response_body) %></pre>
                </div>
              <% else %>
                <div>
                  <span class="text-xs text-slate-500 uppercase">Response Body</span>
                  <p class="text-slate-500 text-sm mt-1 italic">No response body</p>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Metadata -->
          <div>
            <h3 class="text-sm font-medium text-slate-500 uppercase tracking-wide mb-3">Metadata</h3>
            <div class="bg-slate-50 rounded-lg p-3 sm:p-4 grid grid-cols-1 sm:grid-cols-2 gap-4 text-sm">
              <div>
                <span class="text-xs text-slate-500 uppercase">Execution ID</span>
                <p class="font-mono text-slate-700 text-xs break-all"><%= @execution.id %></p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Job ID</span>
                <p class="font-mono text-slate-700 text-xs break-all"><%= @job.id %></p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Created At</span>
                <p class="text-slate-700"><%= format_datetime(@execution.inserted_at) %></p>
              </div>
              <div>
                <span class="text-xs text-slate-500 uppercase">Job Name</span>
                <p class="text-slate-700"><%= @job.name %></p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
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

  defp status_code_color(code) when code >= 200 and code < 300, do: "text-emerald-600"
  defp status_code_color(code) when code >= 300 and code < 400, do: "text-blue-600"
  defp status_code_color(code) when code >= 400 and code < 500, do: "text-amber-600"
  defp status_code_color(_), do: "text-red-600"

  defp format_datetime(nil), do: "—"
  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 2)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 2)}m"

  defp format_response_body(body) when is_binary(body) do
    # Try to pretty-print JSON
    case Jason.decode(body) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      {:error, _} -> body
    end
  end
  defp format_response_body(_), do: ""
end
