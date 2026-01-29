defmodule PrikkeWeb.JobLive.New do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs
  alias Prikke.Jobs.Job

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      changeset = Jobs.change_new_job(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "New Job")
       |> assign(:schedule_type, "cron")
       |> assign_form(changeset)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_event("validate", %{"job" => job_params}, socket) do
    schedule_type = job_params["schedule_type"] || socket.assigns.schedule_type

    changeset =
      %Job{}
      |> Jobs.change_job(job_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:schedule_type, schedule_type)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"job" => job_params}, socket) do
    case Jobs.create_job(socket.assigns.organization, job_params) do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job created successfully")
         |> redirect(to: ~p"/jobs/#{job.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = Map.put(changeset, :action, :validate)
        {:noreply,
         socket
         |> put_flash(:error, "Could not create job. Please check the errors below.")
         |> assign_form(changeset)}
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

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-8 px-4">
      <div class="mb-6">
        <.link navigate={~p"/jobs"} class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1">
          <.icon name="hero-chevron-left" class="w-4 h-4" />
          Back to Jobs
        </.link>
      </div>

      <div class="bg-white border border-slate-200 rounded-lg">
        <div class="px-6 py-4 border-b border-slate-200">
          <h1 class="text-xl font-bold text-slate-900">Create New Job</h1>
          <p class="text-slate-500 mt-1">Schedule a webhook to run on a cron schedule or at a specific time.</p>
        </div>

        <.form
          for={@form}
          id="job-form"
          phx-change="validate"
          phx-submit="save"
          class="p-6 space-y-6"
        >
          <div>
            <label for="job_name" class="block text-sm font-medium text-slate-700 mb-2">Name</label>
            <.input field={@form[:name]} type="text" placeholder="My scheduled job" class="w-full" />
          </div>

          <div>
            <label for="job_url" class="block text-sm font-medium text-slate-700 mb-2">Webhook URL</label>
            <.input field={@form[:url]} type="text" placeholder="https://example.com/webhook" class="w-full" />
          </div>

          <div class="grid grid-cols-2 gap-6">
            <div>
              <label for="job_method" class="block text-sm font-medium text-slate-700 mb-2">Method</label>
              <.input field={@form[:method]} type="select" options={["GET", "POST", "PUT", "PATCH", "DELETE"]} class="w-full" />
            </div>
            <div>
              <label for="job_timeout_ms" class="block text-sm font-medium text-slate-700 mb-2">Timeout (ms)</label>
              <.input field={@form[:timeout_ms]} type="number" min="1000" max="300000" class="w-full" />
            </div>
          </div>

          <div>
            <label for="job_schedule_type" class="block text-sm font-medium text-slate-700 mb-2">Schedule Type</label>
            <.input field={@form[:schedule_type]} type="select" options={[{"Recurring (Cron)", "cron"}, {"One-time", "once"}]} class="w-full" />
          </div>

          <%= if @schedule_type == "cron" do %>
            <div>
              <label for="job_cron_expression" class="block text-sm font-medium text-slate-700 mb-2">
                Cron Expression
              </label>
              <.input field={@form[:cron_expression]} type="text" placeholder="0 * * * *" class="w-full font-mono" />
              <p class="text-sm text-slate-500 mt-2">
                Examples: <code class="bg-slate-100 px-1.5 py-0.5 rounded text-slate-700">* * * * *</code> (every minute),
                <code class="bg-slate-100 px-1.5 py-0.5 rounded text-slate-700">0 * * * *</code> (hourly),
                <code class="bg-slate-100 px-1.5 py-0.5 rounded text-slate-700">0 9 * * *</code> (daily at 9am)
              </p>
            </div>
          <% else %>
            <div>
              <label for="job_scheduled_at" class="block text-sm font-medium text-slate-700 mb-2">
                Scheduled Time (UTC)
              </label>
              <.input field={@form[:scheduled_at]} type="datetime-local" class="w-full" />
            </div>
          <% end %>

          <div>
            <label for="job_headers" class="block text-sm font-medium text-slate-700 mb-2">
              Headers (JSON)
            </label>
            <.input field={@form[:headers_json]} type="textarea" rows="3" placeholder="{}" class="w-full font-mono" />
            <p class="text-sm text-slate-500 mt-2">Optional. JSON object with custom headers.</p>
          </div>

          <div>
            <label for="job_body" class="block text-sm font-medium text-slate-700 mb-2">
              Request Body
            </label>
            <.input field={@form[:body]} type="textarea" rows="4" placeholder="{}" class="w-full font-mono" />
            <p class="text-sm text-slate-500 mt-2">Optional. Request body for POST/PUT/PATCH requests.</p>
          </div>

          <.input field={@form[:enabled]} type="checkbox" label="Enable job immediately" />

          <div class="flex justify-end gap-4 pt-6 border-t border-slate-200">
            <.link navigate={~p"/jobs"} class="px-4 py-2 text-slate-600 hover:text-slate-800">
              Cancel
            </.link>
            <button type="submit" class="px-6 py-2 bg-emerald-500 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors">
              Create Job
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
