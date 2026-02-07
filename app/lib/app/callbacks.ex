defmodule Prikke.Callbacks do
  @moduledoc """
  Sends callback notifications after task executions complete.

  When a task or execution has a `callback_url` configured, the execution result
  is POSTed to that URL after the execution finishes (success, failure, or timeout).

  The callback request is signed with the organization's webhook secret using
  the same HMAC-SHA256 scheme as regular webhook deliveries.

  Callbacks are delivered asynchronously via Task.Supervisor with up to 3 attempts
  and exponential backoff (5s, 20s).
  """

  require Logger

  alias Prikke.WebhookSignature

  @callback_timeout 10_000
  @max_attempts 3
  @backoff_delays [5_000, 20_000]

  @doc """
  Sends a callback for a completed execution, if a callback_url is configured.

  Resolves the callback URL from the execution first, falling back to the task's
  callback_url. Spawns an async task for delivery.

  Expects the execution to have task and task.organization preloaded.
  """
  def send_callback(execution) do
    callback_url = resolve_callback_url(execution)

    if callback_url do
      Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
        do_send_callback(execution, callback_url)
      end)
    else
      :noop
    end
  end

  @doc false
  def resolve_callback_url(execution) do
    execution.callback_url || (execution.task && execution.task.callback_url)
  end

  @doc """
  Builds the JSON payload for a callback notification.
  """
  def build_payload(execution) do
    %{
      event: "execution.completed",
      task_id: execution.task_id,
      execution_id: execution.id,
      status: execution.status,
      status_code: execution.status_code,
      duration_ms: execution.duration_ms,
      response_body: execution.response_body,
      error_message: execution.error_message,
      attempt: execution.attempt,
      scheduled_for: format_datetime(execution.scheduled_for),
      finished_at: format_datetime(execution.finished_at)
    }
  end

  defp do_send_callback(execution, callback_url) do
    payload = build_payload(execution)
    body = Jason.encode!(payload)

    webhook_secret = execution.task.organization.webhook_secret
    signature = WebhookSignature.sign(body, webhook_secret)

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "Runlater/1.0"},
      {"x-runlater-signature", signature},
      {"x-runlater-task-id", execution.task_id},
      {"x-runlater-execution-id", execution.id}
    ]

    deliver_with_retries(callback_url, body, headers, execution.id, 1)
  end

  defp deliver_with_retries(callback_url, body, headers, execution_id, attempt) do
    case Req.post(callback_url, body: body, headers: headers, receive_timeout: @callback_timeout) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info(
          "[Callbacks] Callback sent to #{callback_url} for execution #{execution_id} (attempt #{attempt})"
        )

        :ok

      {:ok, %{status: status}} ->
        Logger.warning(
          "[Callbacks] Callback to #{callback_url} returned status #{status} for execution #{execution_id} (attempt #{attempt})"
        )

        maybe_retry(callback_url, body, headers, execution_id, attempt)

      {:error, reason} ->
        Logger.warning(
          "[Callbacks] Callback to #{callback_url} failed: #{inspect(reason)} for execution #{execution_id} (attempt #{attempt})"
        )

        maybe_retry(callback_url, body, headers, execution_id, attempt)
    end
  end

  defp maybe_retry(_callback_url, _body, _headers, execution_id, attempt)
       when attempt >= @max_attempts do
    Logger.error(
      "[Callbacks] Callback for execution #{execution_id} failed after #{attempt} attempts, giving up"
    )

    :error
  end

  defp maybe_retry(callback_url, body, headers, execution_id, attempt) do
    delay = Enum.at(@backoff_delays, attempt - 1, List.last(@backoff_delays))
    Process.sleep(delay)
    deliver_with_retries(callback_url, body, headers, execution_id, attempt + 1)
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
