defmodule PrikkeWeb.MonitorLive.New do
  use PrikkeWeb, :live_view

  alias Prikke.Monitors
  alias Prikke.Monitors.Monitor

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      changeset = Monitors.change_new_monitor(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "New Monitor")
       |> assign(:failure_notification_mode, "default")
       |> assign(:recovery_notification_mode, "default")
       |> assign_form(changeset)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_event("validate", %{"monitor" => params}, socket) do
    {params, failure_mode, recovery_mode} = cast_notification_overrides(params, socket)

    changeset =
      %Monitor{}
      |> Monitors.change_monitor(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:failure_notification_mode, failure_mode)
     |> assign(:recovery_notification_mode, recovery_mode)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"monitor" => params}, socket) do
    {params, _, _} = cast_notification_overrides(params, socket)

    case Monitors.create_monitor(socket.assigns.organization, params,
           scope: socket.assigns.current_scope
         ) do
      {:ok, monitor} ->
        {:noreply,
         socket
         |> put_flash(:info, "Monitor created successfully")
         |> push_navigate(to: ~p"/monitors/#{monitor.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create monitor")
         |> assign_form(Map.put(changeset, :action, :validate))}
    end
  end

  defp cast_notification_overrides(params, socket) do
    failure_mode = Map.get(params, "failure_notification_mode", socket.assigns.failure_notification_mode)
    recovery_mode = Map.get(params, "recovery_notification_mode", socket.assigns.recovery_notification_mode)

    params =
      params
      |> Map.delete("failure_notification_mode")
      |> Map.delete("recovery_notification_mode")
      |> cast_notification_mode(failure_mode, "notify_on_failure", "on_failure_url")
      |> cast_notification_mode(recovery_mode, "notify_on_recovery", "on_recovery_url")

    {params, failure_mode, recovery_mode}
  end

  defp cast_notification_mode(params, "custom", notify_field, _url_field) do
    Map.put(params, notify_field, nil)
  end

  defp cast_notification_mode(params, "disabled", notify_field, url_field) do
    params |> Map.put(notify_field, false) |> Map.put(url_field, nil)
  end

  defp cast_notification_mode(params, _default, notify_field, url_field) do
    params |> Map.put(notify_field, nil) |> Map.put(url_field, nil)
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mb-4">
        <.link
          navigate={~p"/monitors"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Monitors
        </.link>
      </div>

      <h1 class="text-xl sm:text-2xl font-bold text-slate-900 mb-6">Create New Monitor</h1>

      <div class="glass-card rounded-2xl p-6">
        <.form for={@form} id="monitor-form" phx-change="validate" phx-submit="save" class="space-y-6">
          <.input field={@form[:name]} type="text" label="Name" placeholder="Production Backup" />

          <.input
            field={@form[:schedule_type]}
            type="select"
            label="Schedule Type"
            options={[{"Fixed interval", "interval"}, {"Cron expression", "cron"}]}
          />

          <%= if to_string(@form[:schedule_type].value) == "cron" do %>
            <.input
              field={@form[:cron_expression]}
              type="text"
              label="Cron Expression"
              placeholder="0 * * * *"
            />
          <% else %>
            <.input
              field={@form[:interval_seconds]}
              type="select"
              label="Expected Interval"
              options={[
                {"Every 1 minute", "60"},
                {"Every 5 minutes", "300"},
                {"Every 15 minutes", "900"},
                {"Every 30 minutes", "1800"},
                {"Every hour", "3600"},
                {"Every 6 hours", "21600"},
                {"Every 12 hours", "43200"},
                {"Every 24 hours", "86400"},
                {"Every 7 days", "604800"}
              ]}
            />
          <% end %>

          <.input
            field={@form[:grace_period_seconds]}
            type="select"
            label="Grace Period"
            options={[
              {"No grace period", "0"},
              {"1 minute", "60"},
              {"5 minutes", "300"},
              {"15 minutes", "900"},
              {"30 minutes", "1800"},
              {"1 hour", "3600"}
            ]}
          />

          <p class="text-sm text-slate-500">
            How long to wait after the expected time before alerting.
          </p>

          <div class="pt-4 border-t border-slate-100 mt-4">
            <h3 class="text-sm font-semibold text-slate-900 mb-3">Notifications</h3>
            <p class="text-sm text-slate-500 mb-4">
              Override organization-level notification settings for this monitor.
            </p>

            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Failure notifications
                </label>
                <select
                  name={"#{@form.name}[failure_notification_mode]"}
                  id="monitor_failure_notification_mode"
                  class="w-full px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <option value="default" selected={@failure_notification_mode == "default"}>
                    Default
                  </option>
                  <option value="custom" selected={@failure_notification_mode == "custom"}>
                    Custom URL
                  </option>
                  <option value="disabled" selected={@failure_notification_mode == "disabled"}>
                    Disabled
                  </option>
                </select>
              </div>
              <%= if @failure_notification_mode == "custom" do %>
                <div>
                  <.input
                    field={@form[:on_failure_url]}
                    type="url"
                    label="On failure URL"
                    placeholder="https://..."
                  />
                  <p class="text-xs text-slate-500 mt-1">
                    POST to this URL when the monitor goes down.
                  </p>
                </div>
              <% end %>

              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Recovery notifications
                </label>
                <select
                  name={"#{@form.name}[recovery_notification_mode]"}
                  id="monitor_recovery_notification_mode"
                  class="w-full px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <option value="default" selected={@recovery_notification_mode == "default"}>
                    Default
                  </option>
                  <option value="custom" selected={@recovery_notification_mode == "custom"}>
                    Custom URL
                  </option>
                  <option value="disabled" selected={@recovery_notification_mode == "disabled"}>
                    Disabled
                  </option>
                </select>
              </div>
              <%= if @recovery_notification_mode == "custom" do %>
                <div>
                  <.input
                    field={@form[:on_recovery_url]}
                    type="url"
                    label="On recovery URL"
                    placeholder="https://..."
                  />
                  <p class="text-xs text-slate-500 mt-1">
                    POST to this URL when the monitor recovers after being down.
                  </p>
                </div>
              <% end %>
            </div>
          </div>

          <div class="pt-4">
            <button
              type="submit"
              class="w-full sm:w-auto font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-6 py-2.5 rounded-md transition-colors"
            >
              Create Monitor
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
