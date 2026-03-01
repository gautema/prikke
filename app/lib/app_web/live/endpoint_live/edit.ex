defmodule PrikkeWeb.EndpointLive.Edit do
  use PrikkeWeb, :live_view

  alias Prikke.Endpoints

  @impl true
  def mount(%{"id" => id}, session, socket) do
    org = get_organization(socket, session)

    if org do
      endpoint = Endpoints.get_endpoint!(org, id)
      changeset = Endpoints.change_endpoint(endpoint)

      forward_headers_json =
        if endpoint.forward_headers && endpoint.forward_headers != %{} do
          Jason.encode!(endpoint.forward_headers, pretty: true)
        else
          ""
        end

      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:endpoint, endpoint)
       |> assign(:page_title, "Edit #{endpoint.name}")
       |> assign(:forward_headers_json, forward_headers_json)
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
    {params, forward_headers_json} = parse_forward_headers_json(params)
    params = normalize_forward_urls(params)
    params = cast_notification_overrides(params)

    changeset =
      socket.assigns.endpoint
      |> Endpoints.change_endpoint(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:forward_headers_json, forward_headers_json)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"endpoint" => params}, socket) do
    {params, forward_headers_json} = parse_forward_headers_json(params)
    params = normalize_forward_urls(params)
    params = cast_notification_overrides(params)
    org = socket.assigns.organization
    endpoint = socket.assigns.endpoint

    case Endpoints.update_endpoint(org, endpoint, params, scope: socket.assigns.current_scope) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Endpoint updated")
         |> push_navigate(to: ~p"/endpoints/#{updated.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update endpoint")
         |> assign(:forward_headers_json, forward_headers_json)
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

  defp parse_forward_headers_json(params) do
    json = Map.get(params, "forward_headers_json", "")
    params = Map.delete(params, "forward_headers_json")

    if json == "" or is_nil(json) do
      {Map.put(params, "forward_headers", %{}), json}
    else
      case Jason.decode(json) do
        {:ok, headers} when is_map(headers) ->
          {Map.put(params, "forward_headers", headers), json}

        _ ->
          {params, json}
      end
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
          navigate={~p"/endpoints/#{@endpoint.id}"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to {@endpoint.name}
        </.link>
      </div>

      <h1 class="text-xl sm:text-2xl font-bold text-slate-900 mb-6">Edit Endpoint</h1>

      <div class="glass-card rounded-2xl p-6">
        <.form
          for={@form}
          id="endpoint-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <.input field={@form[:name]} type="text" label="Name" />

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
            <h3 class="text-sm font-semibold text-slate-900 mb-3">Custom Forwarding</h3>
            <p class="text-sm text-slate-500 mb-4">
              Override method, headers, and body for all forwarded requests.
            </p>

            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Custom Method
                </label>
                <select
                  name={@form[:forward_method].name}
                  id="endpoint_forward_method"
                  class="w-full px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >
                  <option
                    value=""
                    selected={
                      is_nil(@form[:forward_method].value) or @form[:forward_method].value == ""
                    }
                  >
                    Use original method
                  </option>
                  <option value="GET" selected={@form[:forward_method].value == "GET"}>GET</option>
                  <option value="POST" selected={@form[:forward_method].value == "POST"}>POST</option>
                  <option value="PUT" selected={@form[:forward_method].value == "PUT"}>PUT</option>
                  <option value="PATCH" selected={@form[:forward_method].value == "PATCH"}>
                    PATCH
                  </option>
                  <option value="DELETE" selected={@form[:forward_method].value == "DELETE"}>
                    DELETE
                  </option>
                </select>
                <p class="text-xs text-slate-500 mt-1">
                  Override the HTTP method for all forwarded requests. Leave empty to forward the original method.
                </p>
              </div>

              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Custom Headers (JSON)
                </label>
                <textarea
                  name="endpoint[forward_headers_json]"
                  id="endpoint_forward_headers_json"
                  rows="3"
                  placeholder="{\u0022Authorization\u0022: \u0022Bearer ...\u0022}"
                  class="w-full px-4 py-2.5 border border-slate-300 rounded-md text-slate-900 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-emerald-600 focus:border-emerald-600"
                >{if @forward_headers_json && @forward_headers_json != "", do: @forward_headers_json, else: ""}</textarea>
                <p class="text-xs text-slate-500 mt-1">
                  These headers are merged with the original webhook headers. Custom headers override originals.
                </p>
              </div>

              <div>
                <.input
                  field={@form[:forward_body]}
                  type="textarea"
                  label="Custom Body"
                  placeholder="Leave empty to forward original body"
                />
                <p class="text-xs text-slate-500 mt-1">
                  When set, replaces the original webhook body for all forwarded requests.
                </p>
              </div>
            </div>
          </div>

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

              <div>
                <.input
                  field={@form[:on_failure_url]}
                  type="url"
                  label="On failure URL"
                  placeholder="https://..."
                />
                <p class="text-xs text-slate-500 mt-1">
                  POST to this URL when a forwarded event fails. Independent of notification settings above.
                </p>
              </div>

              <div>
                <.input
                  field={@form[:on_recovery_url]}
                  type="url"
                  label="On recovery URL"
                  placeholder="https://..."
                />
                <p class="text-xs text-slate-500 mt-1">
                  POST to this URL when a forwarded event recovers after a failure.
                </p>
              </div>
            </div>
          </div>

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
