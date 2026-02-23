defmodule PrikkeWeb.EndpointLive.New do
  use PrikkeWeb, :live_view

  alias Prikke.Endpoints
  alias Prikke.Endpoints.Endpoint

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      changeset = Endpoints.change_new_endpoint(org)

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "New Endpoint")
       |> assign_form(changeset)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket) do
    params = normalize_forward_urls(params)
    params = cast_notification_overrides(params)

    changeset =
      %Endpoint{}
      |> Endpoints.change_endpoint(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"endpoint" => params}, socket) do
    params = normalize_forward_urls(params)
    params = cast_notification_overrides(params)

    case Endpoints.create_endpoint(socket.assigns.organization, params,
           scope: socket.assigns.current_scope
         ) do
      {:ok, endpoint} ->
        {:noreply,
         socket
         |> put_flash(:info, "Endpoint created successfully")
         |> push_navigate(to: ~p"/endpoints/#{endpoint.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create endpoint")
         |> assign_form(Map.put(changeset, :action, :validate))}
    end
  end

  def handle_event("add_url", _params, socket) do
    changeset = socket.assigns.form.source
    current_urls = Ecto.Changeset.get_field(changeset, :forward_urls) || []
    current_urls = if current_urls == [], do: [""], else: current_urls

    if length(current_urls) < 10 do
      new_changeset = Ecto.Changeset.put_change(changeset, :forward_urls, current_urls ++ [""])
      {:noreply, assign_form(socket, new_changeset)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_url", %{"index" => index}, socket) do
    changeset = socket.assigns.form.source
    current_urls = Ecto.Changeset.get_field(changeset, :forward_urls) || [""]
    idx = String.to_integer(index)

    if length(current_urls) > 1 do
      new_urls = List.delete_at(current_urls, idx)
      new_changeset = Ecto.Changeset.put_change(changeset, :forward_urls, new_urls)
      {:noreply, assign_form(socket, new_changeset)}
    else
      {:noreply, socket}
    end
  end

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

  defp normalize_forward_urls(params) do
    case params do
      %{"forward_urls" => urls} when is_map(urls) ->
        url_list =
          urls
          |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "_") end)
          |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
          |> Enum.map(fn {_k, v} -> v end)

        Map.put(params, "forward_urls", url_list)

      _ ->
        params
    end
  end

  defp get_forward_urls_from_form(form) do
    case Ecto.Changeset.get_field(form.source, :forward_urls) do
      nil -> [""]
      [] -> [""]
      urls -> urls
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
          navigate={~p"/endpoints"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Endpoints
        </.link>
      </div>

      <h1 class="text-xl sm:text-2xl font-bold text-slate-900 mb-6">Create New Endpoint</h1>

      <div class="glass-card rounded-2xl p-6">
        <.form
          for={@form}
          id="endpoint-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            placeholder="Stripe webhooks"
          />

          <div>
            <label class="block text-sm font-medium text-slate-700 mb-1">
              Forward URLs
            </label>
            <div class="space-y-2">
              <%= for {url, idx} <- Enum.with_index(get_forward_urls_from_form(@form)) do %>
                <div class="flex items-center gap-2">
                  <input
                    type="text"
                    name={"endpoint[forward_urls][#{idx}]"}
                    value={url}
                    placeholder="https://myapp.com/webhooks/stripe"
                    class="flex-1 px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                  />
                  <%= if length(get_forward_urls_from_form(@form)) > 1 do %>
                    <button
                      type="button"
                      phx-click="remove_url"
                      phx-value-index={idx}
                      class="p-2 text-slate-400 hover:text-red-600 transition-colors"
                      title="Remove URL"
                    >
                      <.icon name="hero-x-mark" class="w-5 h-5" />
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
            <%= if length(get_forward_urls_from_form(@form)) < 10 do %>
              <button
                type="button"
                phx-click="add_url"
                class="mt-2 text-sm text-emerald-600 hover:text-emerald-700 font-medium flex items-center gap-1"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Add URL
              </button>
            <% end %>
            <%= if @form.errors[:forward_urls] do %>
              <p class="text-sm text-red-600 mt-1">
                {elem(hd(List.wrap(@form.errors[:forward_urls])), 0)}
              </p>
            <% end %>
          </div>

          <p class="text-sm text-slate-500">
            Incoming webhooks will be forwarded to these URLs with the original method, headers, and body. Add multiple URLs to fan out the same webhook to multiple destinations.
          </p>

          <.input
            field={@form[:retry_attempts]}
            type="number"
            label="Retry attempts"
            min="0"
            max="10"
          />
          <p class="text-sm text-slate-500 -mt-4">
            Number of times to retry forwarding if it fails (0-10).
          </p>

          <div class="flex items-start gap-3">
            <.input
              field={@form[:use_queue]}
              type="checkbox"
              label="Use queue (serial execution)"
            />
          </div>
          <p class="text-sm text-slate-500 -mt-4">
            When enabled, events are forwarded one at a time. Disable for parallel forwarding when order doesn't matter.
          </p>

          <div class="pt-4 border-t border-slate-100 mt-4">
            <h3 class="text-sm font-semibold text-slate-900 mb-3">Notifications</h3>
            <p class="text-sm text-slate-500 mb-4">
              Override organization-level notification settings for forwarded events.
            </p>

            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Failure notifications
                </label>
                <select
                  name={@form[:notify_on_failure].name}
                  id="endpoint_notify_on_failure"
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
                  id="endpoint_notify_on_recovery"
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

          <div class="pt-4">
            <button
              type="submit"
              class="w-full sm:w-auto font-medium text-white bg-emerald-600 hover:bg-emerald-700 px-6 py-2.5 rounded-md transition-colors"
            >
              Create Endpoint
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
