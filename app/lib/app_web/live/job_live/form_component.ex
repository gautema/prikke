defmodule PrikkeWeb.JobLive.FormComponent do
  use PrikkeWeb, :live_component

  alias Prikke.Jobs

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2 class="text-lg font-semibold text-slate-900 mb-6"><%= @title %></h2>

      <.form
        for={@form}
        id="job-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
        <div>
          <label for="job_name" class="block text-sm font-medium text-slate-700 mb-1">Name</label>
          <.input field={@form[:name]} type="text" placeholder="My scheduled job" class="w-full" />
        </div>

        <div>
          <label for="job_url" class="block text-sm font-medium text-slate-700 mb-1">Webhook URL</label>
          <.input field={@form[:url]} type="text" placeholder="https://example.com/webhook" class="w-full" />
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <label for="job_method" class="block text-sm font-medium text-slate-700 mb-1">Method</label>
            <.input field={@form[:method]} type="select" options={["GET", "POST", "PUT", "PATCH", "DELETE"]} class="w-full" />
          </div>
          <div>
            <label for="job_timeout_ms" class="block text-sm font-medium text-slate-700 mb-1">Timeout (ms)</label>
            <.input field={@form[:timeout_ms]} type="number" min="1000" max="300000" class="w-full" />
          </div>
        </div>

        <div>
          <label for="job_schedule_type" class="block text-sm font-medium text-slate-700 mb-1">Schedule Type</label>
          <.input field={@form[:schedule_type]} type="select" options={[{"Recurring (Cron)", "cron"}, {"One-time", "once"}]} class="w-full" />
        </div>

        <%= if @schedule_type == "cron" do %>
          <div>
            <label for="job_cron_expression" class="block text-sm font-medium text-slate-700 mb-1">
              Cron Expression
            </label>
            <.input field={@form[:cron_expression]} type="text" placeholder="0 * * * *" class="w-full font-mono" />
            <p class="text-xs text-slate-500 mt-1">
              Examples: <code class="bg-slate-100 px-1 rounded">* * * * *</code> (every minute),
              <code class="bg-slate-100 px-1 rounded">0 * * * *</code> (hourly),
              <code class="bg-slate-100 px-1 rounded">0 9 * * *</code> (daily at 9am)
            </p>
          </div>
        <% else %>
          <div>
            <label for="job_scheduled_at" class="block text-sm font-medium text-slate-700 mb-1">
              Scheduled Time (UTC)
            </label>
            <.input field={@form[:scheduled_at]} type="datetime-local" class="w-full" />
          </div>
        <% end %>

        <div>
          <label for="job_headers" class="block text-sm font-medium text-slate-700 mb-1">
            Headers (JSON)
          </label>
          <.input field={@form[:headers_json]} type="textarea" rows="3" placeholder="{}" class="w-full font-mono text-sm" />
          <p class="text-xs text-slate-500 mt-1">Optional. JSON object with custom headers.</p>
        </div>

        <div>
          <label for="job_body" class="block text-sm font-medium text-slate-700 mb-1">
            Request Body
          </label>
          <.input field={@form[:body]} type="textarea" rows="4" placeholder="{}" class="w-full font-mono text-sm" />
          <p class="text-xs text-slate-500 mt-1">Optional. Request body for POST/PUT/PATCH requests.</p>
        </div>

        <div class="flex items-center gap-2">
          <.input field={@form[:enabled]} type="checkbox" />
          <label for="job_enabled" class="text-sm text-slate-700">Enable job immediately</label>
        </div>

        <div class="flex justify-end gap-3 pt-4 border-t border-slate-200">
          <.link patch={@patch} class="px-4 py-2 text-slate-600 hover:text-slate-800">
            Cancel
          </.link>
          <button type="submit" class="px-4 py-2 bg-emerald-500 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors">
            <%= if @action == :new, do: "Create Job", else: "Save Changes" %>
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{job: job} = assigns, socket) do
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

    schedule_type = job.schedule_type || "cron"

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:schedule_type, schedule_type)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"job" => job_params}, socket) do
    job_params = parse_headers(job_params)
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
    save_job(socket, socket.assigns.action, job_params)
  end

  defp save_job(socket, :edit, job_params) do
    case Jobs.update_job(socket.assigns.organization, socket.assigns.job, job_params) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_job(socket, :new, job_params) do
    case Jobs.create_job(socket.assigns.organization, job_params) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp parse_headers(%{"headers_json" => json} = params) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, headers} when is_map(headers) ->
        params
        |> Map.delete("headers_json")
        |> Map.put("headers", headers)

      _ ->
        # Keep the JSON string for validation error display
        params
        |> Map.put("headers", %{})
    end
  end

  defp parse_headers(params), do: params

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
