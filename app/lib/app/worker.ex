defmodule Prikke.Worker do
  @moduledoc """
  Worker GenServer that claims and executes pending task executions.

  ## Lifecycle

  1. Worker starts and immediately tries to claim work
  2. If work found: execute HTTP request, update status, loop
  3. If no work: wait briefly, then try again
  4. After 5 minutes of no work, worker exits normally

  ## Execution Flow

  ```
  claim_next_execution() -> FOR UPDATE SKIP LOCKED
       │
       ├─> nil (no work) -> increment idle counter -> maybe exit
       │
       └─> execution -> execute_request()
                │
                ├─> success -> complete_execution()
                │
                ├─> failure -> fail_execution() -> maybe_retry()
                │
                └─> timeout -> timeout_execution() -> maybe_retry()
  ```

  ## Retries

  One-time tasks retry up to `task.retry_attempts` times with exponential backoff.
  Cron tasks do NOT retry - the next scheduled run is the implicit retry.

  ## HTTP Client

  Uses Req library with connection pooling via Finch.
  Respects task.timeout_ms for request timeout.
  """

  use GenServer, restart: :transient
  require Logger

  alias Prikke.Callbacks
  alias Prikke.Executions
  alias Prikke.Tasks
  alias Prikke.Notifications
  alias Prikke.WebhookSignature

  # How long to wait between polls when no work is found (ms)
  # Uses exponential backoff: starts at base, doubles up to max
  # PubSub :wake ensures instant response to new work regardless of backoff
  @poll_interval_base 2_000
  @poll_interval_max 15_000

  # Exit after this duration of no work (30 seconds)
  @max_idle_ms 30_000

  # Retry backoff: (attempt + 1)² × base_delay
  # With 30s base: 2m, 4.5m, 8m, 12.5m, 18m = ~45m total for 5 retries
  @retry_base_delay_ms 30_000

  ## Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [])
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Trap exits to allow graceful shutdown (finish current request)
    Process.flag(:trap_exit, true)

    # Subscribe to wake notifications (from scheduler when new executions are created)
    Phoenix.PubSub.subscribe(Prikke.PubSub, "workers")

    # Start working immediately
    send(self(), :work)
    {:ok, %{idle_since: nil, poll_interval: @poll_interval_base, working: false}}
  end

  @impl true
  def handle_info(:work, %{shutting_down: true} = state) do
    # Don't claim new work during shutdown
    {:stop, :normal, state}
  end

  def handle_info(:work, state) do
    do_claim(state)
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    # Parent supervisor is shutting down
    Logger.info("[Worker] Received exit signal: #{inspect(reason)}, shutting down gracefully")

    if state.working do
      # Currently working, mark as shutting down and let current work finish
      {:noreply, Map.put(state, :shutting_down, true)}
    else
      # Not working, can exit immediately
      {:stop, :normal, state}
    end
  end

  # Wake signal from PubSub - check for work immediately
  def handle_info(:wake, state) do
    unless state.working do
      send(self(), :work)
    end

    {:noreply, state}
  end

  # Ignore unexpected messages (e.g., from test mailer sending :email messages)
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp do_claim(state) do
    case Executions.claim_next_execution() do
      {:ok, nil} ->
        handle_no_work(state)

      {:ok, execution} ->
        # Got work - execute it
        state = %{state | working: true}
        execute(execution)

        # Reset idle tracking and look for more work soon
        Process.send_after(self(), :work, 50)
        {:noreply, %{state | idle_since: nil, poll_interval: @poll_interval_base, working: false}}

      {:error, reason} ->
        Logger.error("[Worker] Failed to claim execution: #{inspect(reason)}")
        Process.send_after(self(), :work, state.poll_interval)
        {:noreply, %{state | working: false}}
    end
  end

  defp handle_no_work(state) do
    now = System.monotonic_time(:millisecond)
    idle_since = state.idle_since || now
    idle_duration = now - idle_since

    if idle_duration >= @max_idle_ms do
      {:stop, :normal, state}
    else
      next_interval = min(state.poll_interval * 2, @poll_interval_max)
      Process.send_after(self(), :work, state.poll_interval)

      {:noreply, %{state | idle_since: idle_since, poll_interval: next_interval, working: false}}
    end
  end

  defp execute(execution) do
    # Task+org are already preloaded from claim_next_execution
    if is_nil(execution) or not Ecto.assoc_loaded?(execution.task) or is_nil(execution.task) do
      Logger.error("[Worker] Execution or task not found: #{inspect(execution)}")
      return_error(execution)
    else
      task = execution.task
      Logger.info("[Worker] Executing task #{task.name} (#{task.id})")

      # Track start time with millisecond precision for accurate duration
      start_time = System.monotonic_time(:millisecond)

      result = make_request(task, execution)

      # Calculate duration from monotonic clock (more accurate than timestamps)
      duration_ms = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, response} ->
          handle_success(execution, response, duration_ms)

        {:error, %Req.TransportError{reason: :timeout}} ->
          handle_timeout(execution, duration_ms)

        {:error, error} ->
          handle_failure(execution, error, duration_ms)
      end
    end
  end

  defp make_request(task, execution) do
    body = if task.method in ["POST", "PUT", "PATCH"], do: task.body || "", else: ""

    headers =
      build_headers(task.headers)
      |> add_runlater_headers(task, execution, body)

    opts = [
      method: String.downcase(task.method) |> String.to_existing_atom(),
      url: task.url,
      headers: headers,
      receive_timeout: task.timeout_ms,
      # Reuse TLS connections via named Finch pool (connect timeout configured at pool level)
      finch: Prikke.Finch,
      # We handle retries ourselves
      retry: false
    ]

    # Add body for methods that support it
    opts =
      if task.method in ["POST", "PUT", "PATCH"] and task.body do
        Keyword.put(opts, :body, task.body)
      else
        opts
      end

    Req.request(opts)
  end

  defp build_headers(nil), do: []

  defp build_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp add_runlater_headers(headers, task, execution, body) do
    webhook_secret = task.organization.webhook_secret
    runlater_headers = WebhookSignature.build_headers(task.id, execution.id, body, webhook_secret)
    headers ++ runlater_headers
  end

  defp handle_success(execution, response, duration_ms) do
    task = execution.task

    case check_response_assertions(task, response) do
      :ok ->
        Logger.info("[Worker] Task succeeded with status #{response.status} in #{duration_ms}ms")

        {:ok, updated_execution} =
          Executions.complete_execution(execution, %{
            status_code: response.status,
            response_body: truncate_body(response.body),
            duration_ms: duration_ms
          })

        # Reuse preloaded task to avoid redundant DB fetches
        full_execution = %{updated_execution | task: execution.task}

        # Send recovery notification if previous execution failed (async)
        Notifications.notify_recovery(full_execution)

        # Send callback notification (async)
        Callbacks.send_callback(full_execution)

      {:error, error_message} ->
        Logger.warning(
          "[Worker] Task assertion failed: #{error_message} (status #{response.status}) in #{duration_ms}ms"
        )

        {:ok, updated_execution} =
          Executions.fail_execution(execution, %{
            status_code: response.status,
            response_body: truncate_body(response.body),
            error_message: error_message,
            duration_ms: duration_ms
          })

        # Reuse preloaded task to avoid redundant DB fetches
        full_execution = %{updated_execution | task: execution.task}

        # Send failure notification and callback (async)
        Notifications.notify_failure(full_execution)
        Callbacks.send_callback(full_execution)

        # Respect Retry-After header on 429 responses
        retry_after_ms =
          if response.status == 429 do
            parse_retry_after(response.headers)
          end

        maybe_retry(execution, retry_after_ms)
    end
  end

  defp check_response_assertions(task, response) do
    with :ok <- check_status_assertion(task, response.status),
         :ok <- check_body_assertion(task, response.body) do
      :ok
    end
  end

  defp check_status_assertion(%{expected_status_codes: nil}, status) do
    if status >= 200 and status < 300, do: :ok, else: {:error, "HTTP #{status}"}
  end

  defp check_status_assertion(%{expected_status_codes: ""}, status) do
    if status >= 200 and status < 300, do: :ok, else: {:error, "HTTP #{status}"}
  end

  defp check_status_assertion(%{expected_status_codes: codes}, status) do
    allowed = Tasks.parse_status_codes(codes)

    if status in allowed do
      :ok
    else
      {:error, "Assertion failed: status #{status} not in [#{codes}]"}
    end
  end

  defp check_body_assertion(%{expected_body_pattern: nil}, _body), do: :ok
  defp check_body_assertion(%{expected_body_pattern: ""}, _body), do: :ok

  defp check_body_assertion(%{expected_body_pattern: pattern}, body) when is_binary(body) do
    if String.contains?(body, pattern) do
      :ok
    else
      {:error, "Assertion failed: response body does not contain \"#{pattern}\""}
    end
  end

  defp check_body_assertion(%{expected_body_pattern: _pattern}, _body), do: :ok

  defp handle_timeout(execution, duration_ms) do
    Logger.warning("[Worker] Task timed out after #{duration_ms}ms")

    {:ok, updated_execution} = Executions.timeout_execution(execution, duration_ms)

    # Reuse preloaded task to avoid redundant DB fetches
    full_execution = %{updated_execution | task: execution.task}

    # Send failure notification and callback (async)
    Notifications.notify_failure(full_execution)
    Callbacks.send_callback(full_execution)

    maybe_retry(execution, nil)
  end

  defp handle_failure(execution, error, duration_ms) do
    error_message = format_error(error)
    Logger.warning("[Worker] Task failed: #{error_message} after #{duration_ms}ms")

    {:ok, updated_execution} =
      Executions.fail_execution(execution, %{
        error_message: error_message,
        duration_ms: duration_ms
      })

    # Reuse preloaded task to avoid redundant DB fetches
    full_execution = %{updated_execution | task: execution.task}

    # Send failure notification and callback (async)
    Notifications.notify_failure(full_execution)
    Callbacks.send_callback(full_execution)

    maybe_retry(execution, nil)
  end

  defp return_error(nil), do: :ok

  defp return_error(execution) do
    Executions.fail_execution(execution, %{
      error_message: "Internal error: execution or task not found"
    })
  end

  # Retry logic: only one-time tasks retry, cron tasks don't
  # (the next scheduled run is the implicit retry for cron)
  # When retry_after_ms is provided (from 429 Retry-After), use it instead of backoff
  defp maybe_retry(execution, retry_after_ms) do
    task = execution.task

    if task.schedule_type == "once" and execution.attempt < task.retry_attempts do
      # Use Retry-After delay if provided, otherwise exponential backoff
      delay_ms =
        if retry_after_ms do
          # Cap Retry-After at 1 hour to prevent unreasonable delays
          min(retry_after_ms, 3_600_000)
        else
          # Calculate backoff delay: (attempt + 1)² × base_delay
          round(:math.pow(execution.attempt + 1, 2) * @retry_base_delay_ms)
        end

      scheduled_for = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)

      retry_source = if retry_after_ms, do: " (from Retry-After)", else: ""

      Logger.info(
        "[Worker] Scheduling retry #{execution.attempt + 1}/#{task.retry_attempts} in #{delay_ms}ms#{retry_source}"
      )

      case Executions.create_execution_for_task(task, scheduled_for, execution.attempt + 1) do
        {:ok, _retry_execution} ->
          # Wake the scheduler to process the retry when it's due
          Tasks.notify_scheduler()
          :ok

        {:error, reason} ->
          Logger.error("[Worker] Failed to create retry execution: #{inspect(reason)}")
          :error
      end
    else
      :no_retry
    end
  end

  # Max response body size: 256KB
  @max_response_size 256 * 1024

  defp truncate_body(nil), do: nil

  defp truncate_body(body) when is_binary(body) do
    if byte_size(body) > @max_response_size do
      String.slice(body, 0, @max_response_size) <> "... [truncated]"
    else
      body
    end
  end

  defp truncate_body(body), do: inspect(body) |> truncate_body()

  defp parse_retry_after(headers) do
    Prikke.RetryAfter.parse(headers)
  end

  defp format_error(%Req.TransportError{reason: reason}),
    do: "Transport error: #{inspect(reason)}"

  defp format_error(%{message: message}), do: message
  defp format_error(error), do: inspect(error)
end
