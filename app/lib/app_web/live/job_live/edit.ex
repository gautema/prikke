defmodule PrikkeWeb.JobLive.Edit do
  use PrikkeWeb, :live_view

  alias Prikke.Jobs

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      job = Jobs.get_job!(org, id)

      # Convert headers map to JSON string for editing
      headers_json =
        case job.headers do
          nil -> "{}"
          headers when headers == %{} -> "{}"
          headers -> Jason.encode!(headers, pretty: true)
        end

      changeset =
        Jobs.change_job(job)
        |> Ecto.Changeset.put_change(:headers_json, headers_json)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:job, job)
       |> assign(:page_title, "Edit: #{job.name}")
       |> assign(:schedule_type, job.schedule_type)
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
      socket.assigns.job
      |> Jobs.change_job(job_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:schedule_type, schedule_type)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"job" => job_params}, socket) do
    job_params = parse_headers(job_params)

    case Jobs.update_job(socket.assigns.organization, socket.assigns.job, job_params) do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job updated successfully")
         |> redirect(to: ~p"/jobs/#{job.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp parse_headers(%{"headers_json" => json} = params) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, headers} when is_map(headers) ->
        params
        |> Map.delete("headers_json")
        |> Map.put("headers", headers)

      _ ->
        params |> Map.put("headers", %{})
    end
  end

  defp parse_headers(params), do: params

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
        <.link navigate={~p"/jobs/#{@job.id}"} class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1">
          <.icon name="hero-chevron-left" class="w-4 h-4" />
          Back to Job
        </.link>
      </div>

      <div class="bg-white border border-slate-200 rounded-lg">
        <div class="px-6 py-4 border-b border-slate-200">
          <h1 class="text-xl font-bold text-slate-900">Edit Job</h1>
          <p class="text-slate-500 mt-1"><%= @job.name %></p>
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

          <.input field={@form[:enabled]} type="checkbox" label="Job enabled" />

          <div class="flex justify-end gap-4 pt-6 border-t border-slate-200">
            <.link navigate={~p"/jobs/#{@job.id}"} class="px-4 py-2 text-slate-600 hover:text-slate-800">
              Cancel
            </.link>
            <button type="submit" class="px-6 py-2 bg-emerald-500 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors">
              Save Changes
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
