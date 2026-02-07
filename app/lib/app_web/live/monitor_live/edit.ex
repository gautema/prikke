defmodule PrikkeWeb.MonitorLive.Edit do
  use PrikkeWeb, :live_view

  alias Prikke.Monitors

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      monitor = Monitors.get_monitor!(org, id)
      changeset = Monitors.change_monitor(monitor)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:monitor, monitor)
       |> assign(:page_title, "Edit #{monitor.name}")
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
    changeset =
      socket.assigns.monitor
      |> Monitors.change_monitor(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"monitor" => params}, socket) do
    org = socket.assigns.organization
    monitor = socket.assigns.monitor

    case Monitors.update_monitor(org, monitor, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Monitor updated")
         |> push_navigate(to: ~p"/monitors/#{updated.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update monitor")
         |> assign_form(Map.put(changeset, :action, :validate))}
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
        <div class="mb-4">
          <.link
            navigate={~p"/monitors/#{@monitor.id}"}
            class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to {@monitor.name}
          </.link>
        </div>

        <h1 class="text-xl sm:text-2xl font-bold text-slate-900 mb-6">Edit Monitor</h1>

        <div class="glass-card rounded-2xl p-6">
          <.form for={@form} id="monitor-form" phx-change="validate" phx-submit="save" class="space-y-6">
            <.input field={@form[:name]} type="text" label="Name" />

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

            <div class="pt-4">
              <button
                type="submit"
                class="w-full sm:w-auto font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-6 py-2.5 rounded-md transition-colors"
              >
                Save Changes
              </button>
            </div>
          </.form>
        </div>
    </Layouts.app>
    """
  end
end
