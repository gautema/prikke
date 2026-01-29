defmodule Prikke.Worker do
  @moduledoc """
  Worker GenServer that claims and executes pending job executions.

  ## Lifecycle

  1. Worker starts and immediately tries to claim work
  2. If work found: execute HTTP request, update status, loop
  3. If no work: wait briefly, then try again
  4. After @max_idle_polls consecutive empty polls, worker exits normally

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

  One-time jobs retry up to `job.retry_attempts` times with exponential backoff.
  Cron jobs do NOT retry - the next scheduled run is the implicit retry.

  ## HTTP Client

  Uses Req library with connection pooling via Finch.
  Respects job.timeout_ms for request timeout.
  """

  use GenServer, restart: :transient
  require Logger

  alias Prikke.Executions
  alias Prikke.Jobs

  # How long to wait between polls when no work is found (ms)
  @poll_interval 1_000

  # Exit after this many consecutive empty polls
  @max_idle_polls 30

  # Retry backoff multiplier (attempt^2 * base_ms)
  @retry_base_delay_ms 5_000

  ## Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [])
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Start working immediately
    send(self(), :work)
    {:ok, %{idle_polls: 0}}
  end

  @impl true
  def handle_info(:work, state) do
    case Executions.claim_next_execution() do
      {:ok, nil} ->
        # No work available
        new_idle = state.idle_polls + 1

        if new_idle >= @max_idle_polls do
          # Exit normally after being idle too long
          {:stop, :normal, state}
        else
          # Wait and try again
          Process.send_after(self(), :work, @poll_interval)
          {:noreply, %{state | idle_polls: new_idle}}
        end

      {:ok, execution} ->
        # Got work - execute it
        execute(execution)

        # Reset idle counter and look for more work immediately
        send(self(), :work)
        {:noreply, %{state | idle_polls: 0}}

      {:error, reason} ->
        Logger.error("[Worker] Failed to claim execution: #{inspect(reason)}")
        Process.send_after(self(), :work, @poll_interval)
        {:noreply, state}
    end
  end

  ## Private Functions

  defp execute(execution) do
    # Load the job with organization for context
    execution = Executions.get_execution_with_job(execution.id)

    if is_nil(execution) or is_nil(execution.job) do
      Logger.error("[Worker] Execution or job not found: #{inspect(execution)}")
      return_error(execution)
    else
      job = execution.job
      Logger.info("[Worker] Executing job #{job.name} (#{job.id})")

      case make_request(job) do
        {:ok, response} ->
          handle_success(execution, response)

        {:error, %Req.TransportError{reason: :timeout}} ->
          handle_timeout(execution)

        {:error, error} ->
          handle_failure(execution, error)
      end
    end
  end

  defp make_request(job) do
    headers = build_headers(job.headers)

    opts = [
      method: String.downcase(job.method) |> String.to_existing_atom(),
      url: job.url,
      headers: headers,
      receive_timeout: job.timeout_ms,
      connect_options: [timeout: 10_000],
      retry: false  # We handle retries ourselves
    ]

    # Add body for methods that support it
    opts =
      if job.method in ["POST", "PUT", "PATCH"] and job.body do
        Keyword.put(opts, :body, job.body)
      else
        opts
      end

    Req.request(opts)
  end

  defp build_headers(nil), do: []
  defp build_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp handle_success(execution, response) do
    # Consider 2xx as success
    if response.status >= 200 and response.status < 300 do
      Logger.info("[Worker] Job succeeded with status #{response.status}")

      Executions.complete_execution(execution, %{
        status_code: response.status,
        response_body: truncate_body(response.body)
      })
    else
      # Non-2xx is treated as failure
      Logger.warning("[Worker] Job failed with status #{response.status}")

      Executions.fail_execution(execution, %{
        status_code: response.status,
        response_body: truncate_body(response.body),
        error_message: "HTTP #{response.status}"
      })

      maybe_retry(execution)
    end
  end

  defp handle_timeout(execution) do
    Logger.warning("[Worker] Job timed out")

    Executions.timeout_execution(execution)
    maybe_retry(execution)
  end

  defp handle_failure(execution, error) do
    error_message = format_error(error)
    Logger.warning("[Worker] Job failed: #{error_message}")

    Executions.fail_execution(execution, %{
      error_message: error_message
    })

    maybe_retry(execution)
  end

  defp return_error(nil), do: :ok
  defp return_error(execution) do
    Executions.fail_execution(execution, %{
      error_message: "Internal error: execution or job not found"
    })
  end

  # Retry logic: only one-time jobs retry, cron jobs don't
  # (the next scheduled run is the implicit retry for cron)
  defp maybe_retry(execution) do
    job = execution.job

    if job.schedule_type == "once" and execution.attempt < job.retry_attempts do
      # Calculate backoff delay: attempt^2 * base_delay
      delay_ms = :math.pow(execution.attempt + 1, 2) * @retry_base_delay_ms
      delay_ms = round(delay_ms)

      scheduled_for = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)

      Logger.info("[Worker] Scheduling retry #{execution.attempt + 1}/#{job.retry_attempts} in #{delay_ms}ms")

      case Executions.create_execution_for_job(job, scheduled_for, execution.attempt + 1) do
        {:ok, _retry_execution} ->
          # Wake the scheduler to process the retry when it's due
          Jobs.notify_scheduler()
          :ok

        {:error, reason} ->
          Logger.error("[Worker] Failed to create retry execution: #{inspect(reason)}")
          :error
      end
    else
      :no_retry
    end
  end

  defp truncate_body(nil), do: nil
  defp truncate_body(body) when is_binary(body) do
    if byte_size(body) > 10_000 do
      String.slice(body, 0, 10_000) <> "... [truncated]"
    else
      body
    end
  end
  defp truncate_body(body), do: inspect(body) |> truncate_body()

  defp format_error(%Req.TransportError{reason: reason}), do: "Transport error: #{inspect(reason)}"
  defp format_error(%{message: message}), do: message
  defp format_error(error), do: inspect(error)
end
