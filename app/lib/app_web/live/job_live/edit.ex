defmodule PrikkeWeb.JobLive.Edit do
  use PrikkeWeb, :live_view

  import PrikkeWeb.CronBuilder

  alias Prikke.Cron
  alias Prikke.Jobs
  alias Prikke.Jobs.Job

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      case Jobs.get_job(org, id) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Job not found")
           |> redirect(to: ~p"/jobs")}

        job ->
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

          {cron_mode, cron_preset, cron_minute, cron_hour, cron_weekdays, cron_day_of_month} =
            parse_cron_for_builder(job.cron_expression)

          {:ok,
           socket
           |> assign(:organization, org)
           |> assign(:job, job)
           |> assign(:page_title, "Edit: #{job.name}")
           |> assign(:schedule_type, job.schedule_type)
           |> assign(:cron_mode, cron_mode)
           |> assign(:cron_preset, cron_preset)
           |> assign(:cron_minute, cron_minute)
           |> assign(:cron_hour, cron_hour)
           |> assign(:cron_weekdays, cron_weekdays)
           |> assign(:cron_day_of_month, cron_day_of_month)
           |> assign(:test_result, nil)
           |> assign(:testing, false)
           |> assign_form(changeset)}
      end
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
      Job.changeset(socket.assigns.job, job_params, skip_ssrf: true)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:schedule_type, schedule_type)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"job" => job_params}, socket) do
    require Logger
    Logger.info("[JobLive.Edit] Save event received with params: #{inspect(job_params)}")

    job_params = parse_headers(job_params)

    case Jobs.update_job(socket.assigns.organization, socket.assigns.job, job_params,
           scope: socket.assigns.current_scope
         ) do
      {:ok, job} ->
        Logger.info(
          "[JobLive.Edit] Job updated successfully, redirecting to #{~p"/jobs/#{job.id}"}"
        )

        {:noreply,
         socket
         |> put_flash(:info, "Job updated successfully")
         |> redirect(to: ~p"/jobs/#{job.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("[JobLive.Edit] Job update failed: #{inspect(changeset.errors)}")
        # Set action to :validate so errors are displayed
        changeset = Map.put(changeset, :action, :validate)

        {:noreply,
         socket
         |> put_flash(:error, "Could not save job. Please check the errors below.")
         |> assign_form(changeset)}
    end
  end

  def handle_event("set_cron_mode", %{"mode" => mode}, socket) do
    cron_mode = if mode == "simple", do: :simple, else: :advanced

    socket =
      if cron_mode == :simple do
        expr = Cron.compute_cron(
          socket.assigns.cron_preset,
          socket.assigns.cron_minute,
          socket.assigns.cron_hour,
          socket.assigns.cron_weekdays,
          socket.assigns.cron_day_of_month
        )

        update_cron_expression(socket, expr)
      else
        socket
      end

    {:noreply, assign(socket, :cron_mode, cron_mode)}
  end

  def handle_event("set_cron_preset", %{"preset" => preset}, socket) do
    expr = Cron.compute_cron(
      preset,
      socket.assigns.cron_minute,
      socket.assigns.cron_hour,
      socket.assigns.cron_weekdays,
      socket.assigns.cron_day_of_month
    )

    {:noreply,
     socket
     |> assign(:cron_preset, preset)
     |> update_cron_expression(expr)}
  end

  def handle_event("set_cron_hour", %{"cron_hour" => hour}, socket) do
    expr = Cron.compute_cron(
      socket.assigns.cron_preset,
      socket.assigns.cron_minute,
      hour,
      socket.assigns.cron_weekdays,
      socket.assigns.cron_day_of_month
    )

    {:noreply,
     socket
     |> assign(:cron_hour, hour)
     |> update_cron_expression(expr)}
  end

  def handle_event("set_cron_minute", %{"cron_minute" => minute}, socket) do
    expr = Cron.compute_cron(
      socket.assigns.cron_preset,
      minute,
      socket.assigns.cron_hour,
      socket.assigns.cron_weekdays,
      socket.assigns.cron_day_of_month
    )

    {:noreply,
     socket
     |> assign(:cron_minute, minute)
     |> update_cron_expression(expr)}
  end

  def handle_event("toggle_weekday", %{"day" => day}, socket) do
    weekdays = socket.assigns.cron_weekdays

    weekdays =
      if day in weekdays do
        if length(weekdays) > 1, do: List.delete(weekdays, day), else: weekdays
      else
        [day | weekdays]
      end

    expr = Cron.compute_cron(
      socket.assigns.cron_preset,
      socket.assigns.cron_minute,
      socket.assigns.cron_hour,
      weekdays,
      socket.assigns.cron_day_of_month
    )

    {:noreply,
     socket
     |> assign(:cron_weekdays, weekdays)
     |> update_cron_expression(expr)}
  end

  def handle_event("test_url", _, socket) do
    changeset = socket.assigns.form.source

    url = Ecto.Changeset.get_field(changeset, :url)
    method = Ecto.Changeset.get_field(changeset, :method)
    body = Ecto.Changeset.get_field(changeset, :body)
    timeout_ms = parse_timeout(Ecto.Changeset.get_field(changeset, :timeout_ms))
    headers = Ecto.Changeset.get_field(changeset, :headers) || %{}

    task =
      Task.async(fn ->
        Jobs.test_webhook(%{
          url: url,
          method: method,
          headers: headers,
          body: body,
          timeout_ms: timeout_ms
        })
      end)

    {:noreply,
     socket
     |> assign(:testing, true)
     |> assign(:test_result, nil)
     |> assign(:test_task_ref, task.ref)}
  end

  def handle_event("dismiss_test_result", _, socket) do
    {:noreply, assign(socket, :test_result, nil)}
  end

  def handle_event("set_cron_day_of_month", %{"cron_day_of_month" => day}, socket) do
    expr = Cron.compute_cron(
      socket.assigns.cron_preset,
      socket.assigns.cron_minute,
      socket.assigns.cron_hour,
      socket.assigns.cron_weekdays,
      day
    )

    {:noreply,
     socket
     |> assign(:cron_day_of_month, day)
     |> update_cron_expression(expr)}
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    if ref == socket.assigns[:test_task_ref] do
      Process.demonitor(ref, [:flush])
      {:noreply, assign(socket, test_result: result, testing: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) when is_reference(ref) do
    if ref == socket.assigns[:test_task_ref] do
      {:noreply, assign(socket, testing: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp parse_timeout(val) when is_integer(val), do: val

  defp parse_timeout(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 10_000
    end
  end

  defp parse_timeout(_), do: 10_000

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

  defp update_cron_expression(socket, expr) do
    changeset =
      Job.changeset(socket.assigns.job, %{"cron_expression" => expr, "schedule_type" => "cron"}, skip_ssrf: true)
      |> Map.put(:action, :validate)

    assign_form(socket, changeset)
  end

  defp test_result_panel(assigns) do
    ~H"""
    <div id="test-result-panel" class="mb-4 rounded-lg border overflow-hidden">
      <%= case @test_result do %>
        <% {:ok, result} -> %>
          <div class={[
            "px-4 py-3 flex items-center justify-between",
            result.status >= 200 and result.status < 300 && "bg-emerald-50 border-emerald-200",
            (result.status < 200 or result.status >= 300) && "bg-red-50 border-red-200"
          ]}>
            <div class="flex items-center gap-3">
              <%= if result.status >= 200 and result.status < 300 do %>
                <.icon name="hero-check-circle" class="w-5 h-5 text-emerald-600" />
              <% else %>
                <.icon name="hero-x-circle" class="w-5 h-5 text-red-600" />
              <% end %>
              <span class="font-mono text-sm font-medium">HTTP {result.status}</span>
              <span class="text-sm text-slate-500">{result.duration_ms}ms</span>
            </div>
            <button
              type="button"
              phx-click="dismiss_test_result"
              class="text-slate-400 hover:text-slate-600 cursor-pointer"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
          <%= if result.body && result.body != "" do %>
            <div class="px-4 py-3 bg-white/50 border-t border-slate-100">
              <pre class="text-xs font-mono text-slate-700 whitespace-pre-wrap break-all max-h-48 overflow-y-auto"><%= result.body %></pre>
            </div>
          <% end %>
        <% {:error, message} -> %>
          <div class="px-4 py-3 bg-red-50 border-red-200 flex items-center justify-between">
            <div class="flex items-center gap-3">
              <.icon name="hero-x-circle" class="w-5 h-5 text-red-600" />
              <span class="text-sm text-red-700">{message}</span>
            </div>
            <button
              type="button"
              phx-click="dismiss_test_result"
              class="text-slate-400 hover:text-slate-600 cursor-pointer"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
      <% end %>
    </div>
    """
  end

  defp parse_cron_for_builder(nil), do: {:simple, "every_hour", "0", "9", ["1"], "1"}

  defp parse_cron_for_builder(expression) do
    case Cron.parse_to_preset(expression) do
      {preset, minute, hour, weekdays, day_of_month} ->
        {:simple, preset, minute, hour, weekdays, day_of_month}

      :custom ->
        {:advanced, "every_hour", "0", "9", ["1"], "1"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">
      <div class="mb-6">
        <.link
          navigate={~p"/jobs/#{@job.id}"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Job
        </.link>
      </div>

      <div class="mb-6">
        <h1 class="text-2xl font-bold text-slate-900">Edit Job</h1>
        <p class="text-slate-500 mt-1">{@job.name}</p>
      </div>

      <.form
        for={@form}
        id="job-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
        <!-- Basic Info -->
        <div class="glass-card rounded-2xl p-6">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold text-slate-900">Basic Info</h2>
            <label class="flex items-center gap-3 cursor-pointer">
              <span class="text-sm font-medium text-slate-700">Enabled</span>
              <button
                type="button"
                phx-click={JS.dispatch("click", to: "#job_enabled_checkbox")}
                class={[
                  "relative inline-flex h-7 w-12 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:ring-offset-2",
                  Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value) &&
                    "bg-emerald-600",
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
        <div class="glass-card rounded-2xl p-6">
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
              <.cron_builder
                form={@form}
                cron_mode={@cron_mode}
                cron_preset={@cron_preset}
                cron_minute={@cron_minute}
                cron_hour={@cron_hour}
                cron_weekdays={@cron_weekdays}
                cron_day_of_month={@cron_day_of_month}
                tier={@organization.tier}
              />
            <% else %>
              <div>
                <label for="job_scheduled_at" class="block text-sm font-medium text-slate-700 mb-1">
                  Scheduled Time (UTC)
                </label>
                <% existing_value =
                  @form[:scheduled_at].value &&
                    Calendar.strftime(@form[:scheduled_at].value, "%Y-%m-%dT%H:%M") %>
                <input
                  type="datetime-local"
                  name={@form[:scheduled_at].name}
                  id="job_scheduled_at_edit"
                  value={existing_value}
                  phx-hook=".UtcDatetimePickerEdit"
                  class="w-full px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                />
                <%= for msg <- Enum.map(@form[:scheduled_at].errors, &translate_error/1) do %>
                  <p class="mt-1 text-sm text-red-600">{msg}</p>
                <% end %>
              </div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".UtcDatetimePickerEdit">
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
        <div class="glass-card rounded-2xl p-6">
          <div class="flex items-center justify-between mb-4">
            <div>
              <h2 class="text-lg font-semibold text-slate-900">Request Settings</h2>
              <p class="text-sm text-slate-500 mt-1">Configure the HTTP request that will be sent.</p>
            </div>
            <button
              type="button"
              id="test-url-btn"
              phx-click="test_url"
              disabled={@testing}
              class={[
                "px-3 py-1.5 text-sm font-medium rounded-md transition-colors flex items-center gap-1.5 cursor-pointer",
                !@testing && "text-slate-700 bg-slate-100 hover:bg-slate-200 border border-slate-200",
                @testing && "text-slate-400 bg-slate-50 border border-slate-100 cursor-not-allowed"
              ]}
            >
              <%= if @testing do %>
                <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" /> Testing...
              <% else %>
                <.icon name="hero-play" class="w-4 h-4" /> Test URL
              <% end %>
            </button>
          </div>

          <%= if @test_result do %>
            <.test_result_panel test_result={@test_result} />
          <% end %>

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
                class="w-full px-4 py-3 font-mono text-sm bg-white/70 border border-white/50 rounded-md text-slate-900 placeholder-slate-400 min-h-[140px]"
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
                class="w-full px-4 py-3 font-mono text-sm bg-white/70 border border-white/50 rounded-md text-slate-900 placeholder-slate-400 min-h-[200px]"
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

    <!-- Response Assertions -->
        <div class="glass-card rounded-2xl p-6">
          <div class="mb-4">
            <h2 class="text-lg font-semibold text-slate-900">Response Assertions</h2>
            <p class="text-sm text-slate-500 mt-1">Define what counts as a successful response.</p>
          </div>

          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">
                Expected Status Codes
              </label>
              <.input
                field={@form[:expected_status_codes]}
                type="text"
                placeholder="200, 201"
              />
              <p class="text-xs text-slate-500 mt-1">
                Comma-separated (e.g. 200, 201). Leave empty for any 2xx status.
              </p>
            </div>

            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">
                Response Body Contains
              </label>
              <.input
                field={@form[:expected_body_pattern]}
                type="text"
                placeholder="ok"
              />
              <p class="text-xs text-slate-500 mt-1">
                Response must contain this text. Leave empty to accept any body.
              </p>
            </div>
          </div>
        </div>

    <!-- Actions -->
        <div class="flex justify-end gap-4">
          <.link
            navigate={~p"/jobs/#{@job.id}"}
            class="px-4 py-2.5 text-slate-600 hover:text-slate-800"
          >
            Cancel
          </.link>
          <button
            type="submit"
            class="px-6 py-2.5 bg-emerald-600 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors"
          >
            Save Changes
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
