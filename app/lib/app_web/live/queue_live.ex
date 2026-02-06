defmodule PrikkeWeb.QueueLive do
  use PrikkeWeb, :live_view

  import Ecto.Changeset

  alias Prikke.Jobs
  alias Prikke.Executions

  # Define the fields and types for schemaless changeset
  @queue_types %{
    url: :string,
    method: :string,
    headers_json: :string,
    body: :string,
    name: :string,
    callback_url: :string
  }

  @impl true
  def mount(_params, session, socket) do
    org = get_organization(socket, session)

    if org do
      {:ok,
       socket
       |> assign(:organization, org)
       |> assign(:page_title, "Queue Request")
       |> assign(:result, nil)
       |> assign_form(changeset(initial_params()))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please select an organization first")
       |> redirect(to: ~p"/organizations")}
    end
  end

  defp initial_params do
    %{
      "url" => "",
      "method" => "POST",
      "headers_json" => ~s({"Content-Type": "application/json"}),
      "body" => ""
    }
  end

  defp changeset(params, action \\ nil) do
    {%{}, @queue_types}
    |> cast(params, Map.keys(@queue_types))
    |> validate_required([:url])
    |> validate_url(:url)
    |> then(fn cs -> if action, do: Map.put(cs, :action, action), else: cs end)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      url = String.trim(url || "")

      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
          []

        _ ->
          [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end

  @impl true
  def handle_event("validate", %{"queue" => params}, socket) do
    cs = changeset(params, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("queue", %{"queue" => params}, socket) do
    cs = changeset(params, :validate)

    if cs.valid? do
      do_queue(socket, params)
    else
      {:noreply, assign_form(socket, cs)}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:result, nil)
     |> assign_form(changeset(initial_params()))}
  end

  defp do_queue(socket, params) do
    org = socket.assigns.organization

    # Parse headers JSON
    headers =
      case Jason.decode(params["headers_json"] || "{}") do
        {:ok, h} when is_map(h) -> h
        _ -> %{}
      end

    # Schedule 1 second in the future to pass validation
    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(1, :second)
      |> DateTime.truncate(:second)

    url = String.trim(params["url"] || "")
    pretty_time = Calendar.strftime(scheduled_at, "%d %b, %H:%M")
    default_name = "#{url} · #{pretty_time}"

    name =
      case params["name"] do
        nil -> default_name
        "" -> default_name
        n -> n
      end

    callback_url = params["callback_url"]

    job_params = %{
      "name" => name,
      "url" => url,
      "method" => params["method"] || "POST",
      "headers" => headers,
      "body" => params["body"] || "",
      "schedule_type" => "once",
      "scheduled_at" => scheduled_at,
      "enabled" => true,
      "timeout_ms" => 30_000,
      "retry_attempts" => 5,
      "callback_url" => callback_url
    }

    execution_opts =
      if callback_url && callback_url != "" do
        [callback_url: callback_url]
      else
        []
      end

    case Jobs.create_job(org, job_params, scope: socket.assigns.current_scope) do
      {:ok, job} ->
        case Executions.create_execution_for_job(job, scheduled_at, execution_opts) do
          {:ok, execution} ->
            # Clear next_run_at so scheduler doesn't also create an execution
            Jobs.clear_next_run(job)

            {:noreply,
             socket
             |> assign(:result, %{job: job, execution: execution})
             |> put_flash(:info, "Request queued for immediate execution")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to create execution")}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = format_errors(changeset)

        {:noreply,
         socket
         |> put_flash(:error, "Could not queue request: #{errors}")}
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
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
    assign(socket, :form, to_form(changeset, as: :queue))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-8 px-4">
      <div class="mb-6">
        <.link
          navigate={~p"/dashboard"}
          class="text-sm text-slate-500 hover:text-slate-700 flex items-center gap-1"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Back to Dashboard
        </.link>
      </div>

      <div class="mb-6">
        <h1 class="text-2xl font-bold text-slate-900">Queue Request</h1>
        <p class="text-slate-500 mt-1">Send an HTTP request immediately. No scheduling required.</p>
      </div>

      <%= if @result do %>
        <div class="bg-emerald-50 border border-emerald-200 rounded-lg p-6 mb-6">
          <div class="flex items-start gap-3">
            <.icon name="hero-check-circle" class="w-6 h-6 text-emerald-600 mt-0.5" />
            <div class="flex-1">
              <h3 class="font-semibold text-emerald-800">Request Queued</h3>
              <p class="text-sm text-emerald-700 mt-1">
                Your request has been queued and will execute within seconds.
              </p>
              <div class="mt-4 space-y-2 text-sm">
                <div class="flex gap-2">
                  <span class="text-emerald-600 font-medium">Job ID:</span>
                  <code class="text-emerald-800 bg-emerald-100 px-1.5 py-0.5 rounded text-xs">
                    {@result.job.id}
                  </code>
                </div>
                <div class="flex gap-2">
                  <span class="text-emerald-600 font-medium">Execution ID:</span>
                  <code class="text-emerald-800 bg-emerald-100 px-1.5 py-0.5 rounded text-xs">
                    {@result.execution.id}
                  </code>
                </div>
              </div>
              <div class="mt-4 flex gap-3">
                <.link
                  navigate={~p"/jobs/#{@result.job.id}/executions/#{@result.execution.id}"}
                  class="text-sm font-medium text-emerald-700 hover:text-emerald-800 underline"
                >
                  View Execution
                </.link>
                <button
                  type="button"
                  phx-click="reset"
                  class="text-sm font-medium text-emerald-700 hover:text-emerald-800 underline"
                >
                  Queue Another
                </button>
              </div>
            </div>
          </div>
        </div>
      <% else %>
        <.form
          for={@form}
          id="queue-form"
          phx-change="validate"
          phx-submit="queue"
          class="space-y-6"
        >
          <div class="glass-card rounded-2xl p-6 space-y-4">
            <div>
              <label for="queue_url" class="block text-sm font-medium text-slate-700 mb-1">URL</label>
              <.input
                field={@form[:url]}
                type="text"
                placeholder="https://example.com/webhook"
                autofocus
              />
            </div>

            <div>
              <label for="queue_method" class="block text-sm font-medium text-slate-700 mb-1">
                Method
              </label>
              <.input
                field={@form[:method]}
                type="select"
                options={["GET", "POST", "PUT", "PATCH", "DELETE"]}
              />
            </div>

            <div>
              <label for="queue_headers_json" class="block text-sm font-medium text-slate-700 mb-1">
                Headers <span class="text-slate-400 font-normal">(JSON)</span>
              </label>
              <.input
                field={@form[:headers_json]}
                type="textarea"
                rows="6"
                placeholder='{"Content-Type": "application/json"}'
                class="w-full px-4 py-3 font-mono text-sm bg-white/70 border border-white/50 rounded-md text-slate-900 placeholder-slate-400 min-h-[140px]"
              />
            </div>

            <div>
              <label for="queue_body" class="block text-sm font-medium text-slate-700 mb-1">
                Request Body
              </label>
              <.input
                field={@form[:body]}
                type="textarea"
                rows="10"
                placeholder='{"key": "value"}'
                class="w-full px-4 py-3 font-mono text-sm bg-white/70 border border-white/50 rounded-md text-slate-900 placeholder-slate-400 min-h-[200px]"
              />
            </div>

            <div>
              <label for="queue_name" class="block text-sm font-medium text-slate-700 mb-1">
                Name <span class="text-slate-400 font-normal">(optional)</span>
              </label>
              <.input
                field={@form[:name]}
                type="text"
                placeholder="My webhook test"
              />
              <p class="text-xs text-slate-500 mt-1">
                Optional label for easier identification in history.
              </p>
            </div>

            <div>
              <label for="queue_callback_url" class="block text-sm font-medium text-slate-700 mb-1">
                Callback URL <span class="text-slate-400 font-normal">(optional)</span>
              </label>
              <.input
                field={@form[:callback_url]}
                type="text"
                placeholder="https://example.com/callback"
              />
              <p class="text-xs text-slate-500 mt-1">
                Receive a POST with execution results when the request completes.
              </p>
            </div>
          </div>

          <div class="flex justify-end">
            <button
              type="submit"
              phx-disable-with="Queuing..."
              class="px-6 py-2.5 bg-emerald-600 text-white font-medium rounded-md hover:bg-emerald-700 transition-colors flex items-center gap-2"
            >
              <.icon name="hero-bolt" class="w-5 h-5" /> Queue Now
            </button>
          </div>
        </.form>
      <% end %>
    </div>
    """
  end
end
