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
       |> assign(:forward_headers_json, "")
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
  def handle_event("validate", %{"endpoint" => params}, socket) do
    {params, forward_headers_json} = parse_forward_headers_json(params)
    params = normalize_forward_urls(params)
    {params, failure_mode, recovery_mode} = cast_notification_overrides(params, socket)

    changeset =
      %Endpoint{}
      |> Endpoints.change_endpoint(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:forward_headers_json, forward_headers_json)
     |> assign(:failure_notification_mode, failure_mode)
     |> assign(:recovery_notification_mode, recovery_mode)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"endpoint" => params}, socket) do
    {params, forward_headers_json} = parse_forward_headers_json(params)
    params = normalize_forward_urls(params)
    {params, _, _} = cast_notification_overrides(params, socket)

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
                  name={"#{@form.name}[failure_notification_mode]"}
                  id="endpoint_failure_notification_mode"
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
                    POST to this URL when a forwarded event fails.
                  </p>
                </div>
              <% end %>

              <div>
                <label class="block text-sm font-medium text-slate-700 mb-1">
                  Recovery notifications
                </label>
                <select
                  name={"#{@form.name}[recovery_notification_mode]"}
                  id="endpoint_recovery_notification_mode"
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
                    POST to this URL when a forwarded event recovers after a failure.
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
              Create Endpoint
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
