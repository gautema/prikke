defmodule Prikke.HostBlocker do
  @moduledoc """
  Tracks blocked hosts per organization to avoid hammering rate-limited or down APIs.

  Two ETS tables:
  - `:blocked_hosts` — `{org_id, host}` => `{blocked_until, reason}`
  - `:host_failures` — `{org_id, host}` => `{failure_count, escalation_level}`

  ## Blocking triggers

  - **429 responses**: Immediate block using Retry-After header (default 60s).
  - **Repeated 5xx/connection errors**: After 3 consecutive failures, auto-block
    with escalating backoff: 30s → 60s → 120s → 300s (cap at 5 min).

  ## Worker integration

  Before making an HTTP request, the worker checks `blocked?/2`. If blocked,
  the execution is rescheduled to `blocked_until` instead of firing the request.
  """

  use GenServer
  require Logger

  @blocked_table :blocked_hosts
  @failures_table :host_failures
  @cleanup_interval 30_000

  # Number of consecutive failures before auto-blocking
  @failure_threshold 3

  # Escalating backoff durations in milliseconds
  @backoff_durations [30_000, 60_000, 120_000, 300_000]

  # Default block duration for 429 without Retry-After header
  @default_429_duration_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Block all deliveries from `org_id` to `host` for `duration_ms`.
  """
  def block(org_id, host, duration_ms, reason) do
    blocked_until = DateTime.add(DateTime.utc_now(), duration_ms, :millisecond)
    :ets.insert(@blocked_table, {{org_id, host}, {blocked_until, reason}})

    Logger.info(
      "[HostBlocker] Blocked #{host} for org #{short_id(org_id)} for #{duration_ms}ms (#{reason})"
    )

    :ok
  end

  @doc """
  Returns true if `host` is currently blocked for `org_id`.
  """
  def blocked?(org_id, host) do
    case :ets.lookup(@blocked_table, {org_id, host}) do
      [{{_, _}, {blocked_until, _reason}}] ->
        DateTime.compare(DateTime.utc_now(), blocked_until) == :lt

      [] ->
        false
    end
  end

  @doc """
  Returns the DateTime until which `host` is blocked for `org_id`, or nil.
  """
  def blocked_until(org_id, host) do
    case :ets.lookup(@blocked_table, {org_id, host}) do
      [{{_, _}, {blocked_until, _reason}}] ->
        if DateTime.compare(DateTime.utc_now(), blocked_until) == :lt do
          blocked_until
        end

      [] ->
        nil
    end
  end

  @doc """
  Record a failure (5xx or connection error) for `host` under `org_id`.
  Auto-blocks after #{@failure_threshold} consecutive failures with escalating backoff.
  """
  def record_failure(org_id, host) do
    count = :ets.update_counter(@failures_table, {org_id, host}, {2, 1}, {{org_id, host}, 0, 0})

    if count >= @failure_threshold do
      escalation = :ets.lookup_element(@failures_table, {org_id, host}, 3)
      duration_ms = Enum.at(@backoff_durations, escalation, List.last(@backoff_durations))
      new_escalation = min(escalation + 1, length(@backoff_durations) - 1)
      :ets.update_element(@failures_table, {org_id, host}, {3, new_escalation})
      block(org_id, host, duration_ms, :consecutive_failures)
    end

    :ok
  end

  @doc """
  Record a successful request to `host` for `org_id`. Resets failure counter.
  """
  def record_success(org_id, host) do
    :ets.delete(@failures_table, {org_id, host})
    :ok
  end

  @doc """
  Block a host due to a 429 response. Uses Retry-After header duration if available,
  otherwise defaults to #{@default_429_duration_ms}ms.
  """
  def block_rate_limited(org_id, host, retry_after_ms) do
    duration = retry_after_ms || @default_429_duration_ms
    block(org_id, host, duration, :rate_limited)
  end

  @doc """
  Returns the default 429 block duration in milliseconds.
  """
  def default_429_duration_ms, do: @default_429_duration_ms

  ## GenServer callbacks

  @impl true
  def init(_) do
    :ets.new(@blocked_table, [:set, :public, :named_table])
    :ets.new(@failures_table, [:set, :public, :named_table])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = DateTime.utc_now()

    :ets.tab2list(@blocked_table)
    |> Enum.each(fn {{org_id, host}, {blocked_until, _reason}} ->
      if DateTime.compare(now, blocked_until) != :lt do
        :ets.delete(@blocked_table, {org_id, host})
      end
    end)
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: inspect(id)
end
