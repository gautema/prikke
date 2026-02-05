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

    # Default scheduled_at to current UTC time for one-time jobs if not set
    job_params =
      if schedule_type == "once" and
           (job_params["scheduled_at"] == "" or is_nil(job_params["scheduled_at"])) do
        # Default to 5 minutes from now to ensure it's in the future
        default_time =
          DateTime.utc_now()
          |> DateTime.add(5, :minute)
          |> Calendar.strftime("%Y-%m-%dT%H:%M")

        Map.put(job_params, "scheduled_at", default_time)
      else
        job_params
      end

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
    case Jobs.create_job(socket.assigns.organization, job_params,
           scope: socket.assigns.current_scope
         ) do
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
      Prikke.Accounts.get_organization_for_user(user, org_id)
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
    <div class="max-w-4xl mx-auto py-8 px-4">
      <div class="mb-6">
        <.link
          navigate={~p"/dashboard"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Dashboard
        </.link>
      </div>

      <div class="mb-6">
        <h1 class="text-2xl font-bold text-slate-900">Create New Job</h1>
        <p class="text-slate-500 mt-1">Schedule a webhook to run automatically.</p>
      </div>

      <.form
        for={@form}
        id="job-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
        <!-- Basic Info -->
        <div class="bg-white border border-slate-200 rounded-lg p-6">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold text-slate-900">Basic Info</h2>
            <label class="flex items-center gap-3 cursor-pointer">
              <span class="text-sm font-medium text-slate-700">Enable job</span>
              <button
                type="button"
                phx-click={JS.dispatch("click", to: "#job_enabled_checkbox")}
                class={[
                  "relative inline-flex h-7 w-12 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:ring-offset-2",
                  Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value) &&
                    "bg-emerald-500",
                  !Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value) &&
                    "bg-slate-200"
                ]}
              >
                <span class={[
                  "pointer-events-none inline-block h-6 w-6 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                  Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value) &&
                    "translate-x-5",
                  !Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value) &&
                    "translate-x-0"
                ]}>
                </span>
              </button>
              <input type="hidden" name={@form[:enabled].name} value="false" />
              <input
                type="checkbox"
                id="job_enabled_checkbox"
                name={@form[:enabled].name}
                value="true"
                checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value)}
                class="sr-only"
              />
            </label>
          </div>

          <div class="space-y-4">
            <div>
              <label for="job_name" class="block text-sm font-medium text-slate-700 mb-1">Name</label>
              <.input field={@form[:name]} type="text" placeholder="My scheduled job" />
            </div>

            <div>
              <label for="job_url" class="block text-sm font-medium text-slate-700 mb-1">
                Webhook URL
              </label>
              <.input field={@form[:url]} type="text" placeholder="https://example.com/webhook" />
            </div>
          </div>
        </div>
        
    <!-- Schedule -->
        <div class="bg-white border border-slate-200 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Schedule</h2>

          <div class="space-y-4">
            <div>
              <label for="job_schedule_type" class="block text-sm font-medium text-slate-700 mb-1">
                Schedule Type
              </label>
              <.input
                field={@form[:schedule_type]}
                type="select"
                options={[{"Recurring (Cron)", "cron"}, {"One-time", "once"}]}
              />
            </div>

            <%= if @schedule_type == "cron" do %>
              <div>
                <label for="job_cron_expression" class="block text-sm font-medium text-slate-700 mb-1">
                  Cron Expression
                </label>
                <.input
                  field={@form[:cron_expression]}
                  type="text"
                  placeholder="0 * * * *"
                  class="w-full px-4 py-3 font-mono text-base bg-slate-50 border border-slate-300 rounded-md text-slate-900 placeholder-slate-400"
                />
                <p class="text-sm text-slate-500 mt-2">
                  Examples:
                  <code class="bg-slate-100 px-1.5 py-0.5 rounded text-slate-700 font-mono">
                    * * * * *
                  </code>
                  (every minute),
                  <code class="bg-slate-100 px-1.5 py-0.5 rounded text-slate-700 font-mono">
                    0 * * * *
                  </code>
                  (hourly),
                  <code class="bg-slate-100 px-1.5 py-0.5 rounded text-slate-700 font-mono">
                    0 9 * * *
                  </code>
                  (daily at 9am)
                </p>
              </div>
            <% else %>
              <div phx-feedback-for={@form[:scheduled_at].name}>
                <label for="job_scheduled_at" class="block text-sm font-medium text-slate-700 mb-1">
                  Scheduled Time (UTC)
                </label>
                <input
                  type="datetime-local"
                  name={@form[:scheduled_at].name}
                  id="job_scheduled_at"
                  value={@form[:scheduled_at].value}
                  phx-hook=".UtcDatetimePicker"
                  class={[
                    "w-full px-4 py-2.5 border rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-500 focus:border-emerald-500",
                    @form[:scheduled_at].errors != [] && "border-red-500",
                    @form[:scheduled_at].errors == [] && "border-slate-300"
                  ]}
                />
                <%= for msg <- Enum.map(@form[:scheduled_at].errors, &translate_error/1) do %>
                  <p class="mt-1 text-sm text-red-600 phx-no-feedback:hidden">{msg}</p>
                <% end %>
              </div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".UtcDatetimePicker">
                export default {
                  mounted() {
                    const input = this.el;
                    // Set min to current UTC time
                    const now = new Date();
                    const utcString = now.toISOString().slice(0, 16);
                    input.min = utcString;
                  }
                }
              </script>
            <% end %>
          </div>
        </div>
        
    <!-- Request Settings -->
        <div class="bg-white border border-slate-200 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-slate-900 mb-4">Request Settings</h2>
          <p class="text-sm text-slate-500 mb-4">Configure the HTTP request that will be sent.</p>

          <div class="space-y-4">
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label for="job_method" class="block text-sm font-medium text-slate-700 mb-1">
                  Method
                </label>
                <.input
                  field={@form[:method]}
                  type="select"
                  options={["GET", "POST", "PUT", "PATCH", "DELETE"]}
                />
              </div>
              <div>
                <label for="job_timeout_ms" class="block text-sm font-medium text-slate-700 mb-1">
                  Timeout (ms)
                </label>
                <.input field={@form[:timeout_ms]} type="number" min="1000" max="300000" />
              </div>
            </div>

            <div>
              <label for="job_headers" class="block text-sm font-medium text-slate-700 mb-1">
                Headers <span class="text-slate-400 font-normal">(JSON)</span>
              </label>
              <.input
                field={@form[:headers_json]}
                type="textarea"
                rows="6"
                placeholder='{"Content-Type": "application/json"}'
                class="w-full px-4 py-3 font-mono text-sm bg-slate-50 border border-slate-300 rounded-md text-slate-900 placeholder-slate-400 min-h-[140px]"
              />
              <p class="text-xs text-slate-500 mt-1">Optional. JSON object with custom headers.</p>
            </div>

            <div>
              <label for="job_body" class="block text-sm font-medium text-slate-700 mb-1">
                Request Body
              </label>
              <.input
                field={@form[:body]}
                type="textarea"
                rows="10"
                placeholder='{"key": "value"}'
                class="w-full px-4 py-3 font-mono text-sm bg-slate-50 border border-slate-300 rounded-md text-slate-900 placeholder-slate-400 min-h-[200px]"
              />
              <p class="text-xs text-slate-500 mt-1">Optional. For POST/PUT/PATCH requests.</p>
            </div>

            <div>
              <label for="job_callback_url" class="block text-sm font-medium text-slate-700 mb-1">
                Callback URL <span class="text-slate-400 font-normal">(optional)</span>
              </label>
              <.input
                field={@form[:callback_url]}
                type="text"
                placeholder="https://example.com/callback"
              />
              <p class="text-xs text-slate-500 mt-1">
                Receive a POST with execution results after each run completes.
              </p>
            </div>
          </div>
        </div>

    <!-- Actions -->
        <div class="flex justify-end gap-4">
          <.link navigate={~p"/jobs"} class="px-4 py-2.5 text-slate-600 hover:text-slate-800">
            Cancel
          </.link>
          <button
            type="submit"
            class="px-6 py-2.5 bg-emerald-500 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors"
          >
            Create Job
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
