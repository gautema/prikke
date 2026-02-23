defmodule PrikkeWeb.TaskLive.New do
  use PrikkeWeb, :live_view

  import PrikkeWeb.CronBuilder

  alias Prikke.Cron
  alias Prikke.Executions
  alias Prikke.Tasks
  alias Prikke.Tasks.Task

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      changeset = Tasks.change_new_task(org, %{"schedule_type" => "once"})

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "New Task")
       |> assign(:timing_mode, "immediate")
       |> assign(:selected_delay, "5m")
       |> assign(:custom_delay_amount, "30")
       |> assign(:custom_delay_unit, "m")
       |> assign(:cron_mode, :simple)
       |> assign(:cron_preset, "every_hour")
       |> assign(:cron_minute, "0")
       |> assign(:cron_hour, "9")
       |> assign(:cron_weekdays, ["1"])
       |> assign(:cron_day_of_month, "1")
       |> assign(:test_result, nil)
       |> assign(:testing, false)
       |> assign_form(changeset)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_event("validate", %{"task" => task_params} = params, socket) do
    timing_mode = params["timing_mode"] || socket.assigns.timing_mode
    schedule_type = if timing_mode == "cron", do: "cron", else: "once"

    task_params =
      task_params |> Map.put("schedule_type", schedule_type) |> cast_notification_overrides()

    task_params =
      case timing_mode do
        mode when mode in ["immediate", "delay"] ->
          delay = if mode == "delay", do: resolve_delay(socket.assigns), else: 0

          scheduled_at =
            DateTime.utc_now()
            |> DateTime.add(delay)
            |> Calendar.strftime("%Y-%m-%dT%H:%M")

          Map.put(task_params, "scheduled_at", scheduled_at)

        "schedule" ->
          if task_params["scheduled_at"] in ["", nil] do
            scheduled_at =
              DateTime.utc_now()
              |> DateTime.add(5, :minute)
              |> Calendar.strftime("%Y-%m-%dT%H:%M")

            Map.put(task_params, "scheduled_at", scheduled_at)
          else
            task_params
          end

        _ ->
          task_params
      end

    changeset =
      Task.changeset(%Task{}, task_params, skip_ssrf: true)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:timing_mode, timing_mode)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"task" => task_params}, socket) do
    task_params = cast_notification_overrides(task_params)

    task_params =
      case socket.assigns.timing_mode do
        "immediate" ->
          task_params
          |> Map.put("schedule_type", "once")
          |> Map.put("scheduled_at", Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M"))

        "delay" ->
          scheduled_at =
            DateTime.utc_now()
            |> DateTime.add(resolve_delay(socket.assigns))
            |> Calendar.strftime("%Y-%m-%dT%H:%M")

          task_params
          |> Map.put("schedule_type", "once")
          |> Map.put("scheduled_at", scheduled_at)

        "schedule" ->
          Map.put(task_params, "schedule_type", "once")

        "cron" ->
          Map.put(task_params, "schedule_type", "cron")
      end

    if socket.assigns.timing_mode in ["immediate", "delay"] do
      # skip_next_run: task is created with next_run_at=nil, no UPDATE needed
      result =
        Prikke.Repo.transaction(fn ->
          case Tasks.create_task(socket.assigns.organization, task_params,
                 scope: socket.assigns.current_scope,
                 skip_next_run: true
               ) do
            {:ok, task} ->
              scheduled_at = task.scheduled_at || DateTime.utc_now()
              {:ok, _exec} = Executions.create_execution_for_task(task, scheduled_at)
              task

            {:error, changeset} ->
              Prikke.Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, task} ->
          Tasks.notify_workers()

          {:noreply,
           socket
           |> put_flash(:info, "Task created successfully")
           |> redirect(to: ~p"/tasks/#{task.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          changeset = Map.put(changeset, :action, :validate)

          {:noreply,
           socket
           |> put_flash(:error, "Could not create task. Please check the errors below.")
           |> assign_form(changeset)}
      end
    else
      # Cron/scheduled tasks — scheduler handles execution creation
      case Tasks.create_task(socket.assigns.organization, task_params,
             scope: socket.assigns.current_scope
           ) do
        {:ok, task} ->
          {:noreply,
           socket
           |> put_flash(:info, "Task created successfully")
           |> redirect(to: ~p"/tasks/#{task.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          changeset = Map.put(changeset, :action, :validate)

          {:noreply,
           socket
           |> put_flash(:error, "Could not create task. Please check the errors below.")
           |> assign_form(changeset)}
      end
    end
  end

  def handle_event("set_delay", %{"delay" => delay}, socket) do
    {:noreply, assign(socket, :selected_delay, delay)}
  end

  def handle_event("update_custom_delay", params, socket) do
    amount = params["amount"] || socket.assigns.custom_delay_amount
    unit = params["unit"] || socket.assigns.custom_delay_unit

    {:noreply,
     socket
     |> assign(:custom_delay_amount, amount)
     |> assign(:custom_delay_unit, unit)}
  end

  def handle_event("set_cron_mode", %{"mode" => mode}, socket) do
    cron_mode = if mode == "simple", do: :simple, else: :advanced

    socket =
      if cron_mode == :simple do
        # Recompute expression from builder state
        expr =
          Cron.compute_cron(
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
    expr =
      Cron.compute_cron(
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
    expr =
      Cron.compute_cron(
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
    expr =
      Cron.compute_cron(
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
        # Don't allow deselecting the last day
        if length(weekdays) > 1, do: List.delete(weekdays, day), else: weekdays
      else
        [day | weekdays]
      end

    expr =
      Cron.compute_cron(
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

    url = Ecto.Changeset.get_field(changeset, :url) || ""
    method = Ecto.Changeset.get_field(changeset, :method) || "GET"
    body = Ecto.Changeset.get_field(changeset, :body)
    timeout_ms = parse_timeout(Ecto.Changeset.get_field(changeset, :timeout_ms))
    headers = Ecto.Changeset.get_field(changeset, :headers) || %{}

    async_task =
      Elixir.Task.async(fn ->
        Tasks.test_webhook(%{
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
     |> assign(:test_task_ref, async_task.ref)}
  end

  def handle_event("dismiss_test_result", _, socket) do
    {:noreply, assign(socket, :test_result, nil)}
  end

  def handle_event("set_cron_day_of_month", %{"cron_day_of_month" => day}, socket) do
    expr =
      Cron.compute_cron(
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

  defp resolve_delay(%{selected_delay: "custom"} = assigns) do
    delay_to_seconds("custom", assigns.custom_delay_amount, assigns.custom_delay_unit)
  end

  defp resolve_delay(%{selected_delay: preset}), do: delay_to_seconds(preset)

  defp delay_to_seconds("custom", amount, unit) do
    n = parse_pos_int(amount, 1)

    case unit do
      "m" -> n * 60
      "h" -> n * 3600
      "d" -> n * 86_400
      _ -> n * 60
    end
  end

  defp delay_to_seconds("5m"), do: 5 * 60
  defp delay_to_seconds("10m"), do: 10 * 60
  defp delay_to_seconds("15m"), do: 15 * 60
  defp delay_to_seconds("1h"), do: 3600
  defp delay_to_seconds("6h"), do: 6 * 3600
  defp delay_to_seconds("12h"), do: 12 * 3600
  defp delay_to_seconds("1d"), do: 86_400
  defp delay_to_seconds("7d"), do: 7 * 86_400
  defp delay_to_seconds("30d"), do: 30 * 86_400
  defp delay_to_seconds(_), do: 5 * 60

  defp parse_pos_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_pos_int(_, default), do: default

  defp parse_timeout(val) when is_integer(val), do: val

  defp parse_timeout(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 10_000
    end
  end

  defp parse_timeout(_), do: 10_000

  defp cast_notification_overrides(params) do
    params
    |> cast_notification_field("notify_on_failure")
    |> cast_notification_field("notify_on_recovery")
  end

  defp cast_notification_field(params, field) do
    case Map.get(params, field) do
      "" -> Map.put(params, field, nil)
      "true" -> Map.put(params, field, true)
      "false" -> Map.put(params, field, false)
      _ -> params
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

  defp update_cron_expression(socket, expr) do
    current_params = socket.assigns.form.source.params || %{}

    changeset =
      %Task{}
      |> Task.changeset(
        Map.merge(current_params, %{"cron_expression" => expr, "schedule_type" => "cron"}),
        skip_ssrf: true
      )
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
            (result.status >= 200 and result.status < 300) && "bg-emerald-50 border-emerald-200",
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto py-8 px-2 sm:px-4">
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard"}
            class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Dashboard
          </.link>
        </div>

        <div class="mb-6">
          <h1 class="text-2xl font-bold text-slate-900">Create New Task</h1>
          <p class="text-slate-500 mt-1">Schedule a webhook to run automatically.</p>
        </div>

        <.form
          for={@form}
          id="task-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <!-- Basic Info -->
          <div class="glass-card rounded-2xl p-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold text-slate-900">Basic Info</h2>
              <label class="flex items-center gap-3 cursor-pointer">
                <span class="text-sm font-medium text-slate-700">Enable task</span>
                <button
                  type="button"
                  phx-click={JS.dispatch("click", to: "#task_enabled_checkbox")}
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
                  id="task_enabled_checkbox"
                  name={@form[:enabled].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:enabled].value)}
                  class="sr-only"
                />
              </label>
            </div>

            <div class="space-y-4">
              <div>
                <label for="task_name" class="block text-sm font-medium text-slate-700 mb-1">
                  Name
                </label>
                <.input field={@form[:name]} type="text" placeholder="My task" />
              </div>

              <div>
                <label for="task_url" class="block text-sm font-medium text-slate-700 mb-1">
                  Target URL
                </label>
                <.input field={@form[:url]} type="text" placeholder="https://example.com/webhook" />
              </div>
            </div>
          </div>
          
    <!-- Type -->
          <div class="glass-card rounded-2xl p-6">
            <h2 class="text-lg font-semibold text-slate-900 mb-4">Type</h2>
            <input
              type="hidden"
              name="task[schedule_type]"
              value={if @timing_mode == "cron", do: "cron", else: "once"}
            />

            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">When to run</label>
                <select
                  name="timing_mode"
                  class="w-full px-3 py-2 border border-slate-300 rounded-md text-slate-900 bg-white focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <option value="immediate" selected={@timing_mode == "immediate"}>Immediate</option>
                  <option value="delay" selected={@timing_mode == "delay"}>Delayed</option>
                  <option value="schedule" selected={@timing_mode == "schedule"}>Scheduled</option>
                  <option value="cron" selected={@timing_mode == "cron"}>Recurring (Cron)</option>
                </select>
              </div>

              <%= if @timing_mode == "immediate" do %>
                <p class="text-sm text-slate-500">
                  This task will execute immediately after creation.
                </p>
              <% end %>

              <%= if @timing_mode == "delay" do %>
                <div>
                  <label class="block text-sm font-medium text-slate-700 mb-2">Run after</label>
                  <div class="flex flex-wrap gap-2">
                    <%= for {label, value} <- [{"5 min", "5m"}, {"10 min", "10m"}, {"15 min", "15m"}, {"1 hour", "1h"}, {"6 hours", "6h"}, {"12 hours", "12h"}, {"1 day", "1d"}, {"7 days", "7d"}, {"30 days", "30d"}, {"Custom", "custom"}] do %>
                      <button
                        type="button"
                        phx-click="set_delay"
                        phx-value-delay={value}
                        class={[
                          "px-3 py-1.5 text-sm font-medium rounded-full border transition-colors cursor-pointer",
                          @selected_delay == value && "bg-emerald-600 text-white border-emerald-600",
                          @selected_delay != value &&
                            "bg-white text-slate-600 border-slate-300 hover:border-emerald-400 hover:text-emerald-600"
                        ]}
                      >
                        {label}
                      </button>
                    <% end %>
                  </div>
                  <%= if @selected_delay == "custom" do %>
                    <div class="flex items-center gap-2 mt-3">
                      <input
                        type="number"
                        min="1"
                        value={@custom_delay_amount}
                        phx-change="update_custom_delay"
                        name="amount"
                        class="w-24 px-3 py-1.5 text-sm border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                      />
                      <select
                        name="unit"
                        phx-change="update_custom_delay"
                        class="px-3 py-1.5 text-sm border border-slate-300 rounded-md text-slate-900 bg-white focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                      >
                        <option value="m" selected={@custom_delay_unit == "m"}>minutes</option>
                        <option value="h" selected={@custom_delay_unit == "h"}>hours</option>
                        <option value="d" selected={@custom_delay_unit == "d"}>days</option>
                      </select>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%= if @timing_mode == "schedule" do %>
                <div phx-feedback-for={@form[:scheduled_at].name}>
                  <label for="task_scheduled_at" class="block text-sm font-medium text-slate-700 mb-1">
                    Scheduled Time
                  </label>
                  <input
                    type="datetime-local"
                    id="task_scheduled_at"
                    phx-hook=".LocalDatetimePicker"
                    class={[
                      "w-full px-4 py-2.5 border rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600",
                      @form[:scheduled_at].errors != [] && "border-red-500",
                      @form[:scheduled_at].errors == [] && "border-slate-300"
                    ]}
                  />
                  <input
                    type="hidden"
                    name={@form[:scheduled_at].name}
                    id="task_scheduled_at_utc"
                    value={@form[:scheduled_at].value}
                  />
                  <p id="task_scheduled_at_utc_label" class="mt-1 text-xs text-slate-500"></p>
                  <%= for msg <- Enum.map(@form[:scheduled_at].errors, &translate_error/1) do %>
                    <p class="mt-1 text-sm text-red-600 phx-no-feedback:hidden">{msg}</p>
                  <% end %>
                </div>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalDatetimePicker">
                  export default {
                    mounted() {
                      this.setupPicker();
                    },
                    updated() {
                      this.setupPicker();
                    },
                    setupPicker() {
                      const input = this.el;
                      const hidden = document.getElementById("task_scheduled_at_utc");
                      const label = document.getElementById("task_scheduled_at_utc_label");

                      // Set min to current local time
                      const now = new Date();
                      const localNow = new Date(now.getTime() - now.getTimezoneOffset() * 60000);
                      input.min = localNow.toISOString().slice(0, 16);

                      // If hidden has existing UTC value, convert to local for display
                      if (hidden.value && !input.value) {
                        const raw = hidden.value.replace(/Z$/, "");
                        const utcDate = new Date(raw + "Z");
                        const localDate = new Date(utcDate.getTime() - utcDate.getTimezoneOffset() * 60000);
                        input.value = localDate.toISOString().slice(0, 16);
                        this.updateUtcLabel(utcDate, label);
                      }

                      input.addEventListener("input", () => {
                        if (!input.value) {
                          hidden.value = "";
                          label.textContent = "";
                          return;
                        }
                        const localDate = new Date(input.value);
                        const utcISO = localDate.toISOString().slice(0, 16);
                        hidden.value = utcISO;
                        hidden.dispatchEvent(new Event("input", { bubbles: true }));
                        this.updateUtcLabel(localDate, label);
                      });
                    },
                    updateUtcLabel(date, label) {
                      const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
                      const d = date.getUTCDate();
                      const mon = months[date.getUTCMonth()];
                      const y = date.getUTCFullYear();
                      const h = String(date.getUTCHours()).padStart(2, "0");
                      const m = String(date.getUTCMinutes()).padStart(2, "0");
                      label.textContent = d + " " + mon + " " + y + ", " + h + ":" + m + " UTC";
                    }
                  }
                </script>
              <% end %>

              <%= if @timing_mode == "cron" do %>
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
              <% end %>
            </div>
          </div>
          
    <!-- Request Settings -->
          <div class="glass-card rounded-2xl p-6">
            <div class="flex items-center justify-between mb-4">
              <div>
                <h2 class="text-lg font-semibold text-slate-900">Request Settings</h2>
                <p class="text-sm text-slate-500 mt-1">
                  Configure the HTTP request that will be sent.
                </p>
              </div>
              <button
                type="button"
                id="test-url-btn"
                phx-click="test_url"
                disabled={@testing}
                class={[
                  "px-3 py-1.5 text-sm font-medium rounded-md transition-colors flex items-center gap-1.5 cursor-pointer",
                  !@testing &&
                    "text-slate-700 bg-slate-100 hover:bg-slate-200 border border-slate-200",
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
                  <label for="task_method" class="block text-sm font-medium text-slate-700 mb-1">
                    Method
                  </label>
                  <.input
                    field={@form[:method]}
                    type="select"
                    options={["GET", "POST", "PUT", "PATCH", "DELETE"]}
                  />
                </div>
                <div>
                  <label for="task_timeout_ms" class="block text-sm font-medium text-slate-700 mb-1">
                    Timeout (ms)
                  </label>
                  <.input field={@form[:timeout_ms]} type="number" min="1000" max="300000" />
                </div>
              </div>

              <div>
                <label for="task_headers" class="block text-sm font-medium text-slate-700 mb-1">
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
                <label for="task_body" class="block text-sm font-medium text-slate-700 mb-1">
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
                <label for="task_callback_url" class="block text-sm font-medium text-slate-700 mb-1">
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

              <div>
                <label for="task_queue" class="block text-sm font-medium text-slate-700 mb-1">
                  Queue <span class="text-slate-400 font-normal">(optional)</span>
                </label>
                <.input
                  field={@form[:queue]}
                  type="text"
                  placeholder="payments"
                />
                <p class="text-xs text-slate-500 mt-1">
                  Named queue for serialized execution. Tasks in the same queue run one at a time
                  within your organization — the next task won't start until the current one finishes.
                  Useful for ordering-sensitive work like payment processing or sequential API calls.
                  Leave empty for default parallel execution.
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
          
    <!-- Notifications -->
          <div class="glass-card rounded-2xl p-6">
            <div class="mb-4">
              <h2 class="text-lg font-semibold text-slate-900">Notifications</h2>
              <p class="text-sm text-slate-500 mt-1">
                Override organization-level notification settings for this task.
              </p>
            </div>

            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Failure notifications
                </label>
                <select
                  name={@form[:notify_on_failure].name}
                  id="task_notify_on_failure"
                  class="w-full px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <option value="" selected={is_nil(@form[:notify_on_failure].value)}>
                    Use org default
                  </option>
                  <option
                    value="true"
                    selected={@form[:notify_on_failure].value == true}
                  >
                    Enabled
                  </option>
                  <option
                    value="false"
                    selected={@form[:notify_on_failure].value == false}
                  >
                    Disabled
                  </option>
                </select>
              </div>

              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Recovery notifications
                </label>
                <select
                  name={@form[:notify_on_recovery].name}
                  id="task_notify_on_recovery"
                  class="w-full px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <option value="" selected={is_nil(@form[:notify_on_recovery].value)}>
                    Use org default
                  </option>
                  <option
                    value="true"
                    selected={@form[:notify_on_recovery].value == true}
                  >
                    Enabled
                  </option>
                  <option
                    value="false"
                    selected={@form[:notify_on_recovery].value == false}
                  >
                    Disabled
                  </option>
                </select>
              </div>
            </div>
          </div>
          
    <!-- Actions -->
          <div class="flex justify-end gap-4">
            <.link navigate={~p"/tasks"} class="px-4 py-2.5 text-slate-600 hover:text-slate-800">
              Cancel
            </.link>
            <button
              type="submit"
              class="px-6 py-2.5 bg-emerald-600 text-white font-medium rounded-md hover:bg-emerald-600 transition-colors"
            >
              Create Task
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
