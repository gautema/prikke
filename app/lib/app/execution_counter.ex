defmodule Prikke.ExecutionCounter do
  @moduledoc """
  Buffers hot-path DB writes in ETS and flushes to DB periodically.

  Buffers two things:
  1. Monthly execution count increments (organizations table)
  2. Last execution timestamps (tasks table)

  This eliminates row-level lock contention under load by batching
  many per-execution UPDATEs into periodic bulk writes.
  """

  use GenServer

  import Ecto.Query, warn: false

  @counter_table :execution_counters
  @timestamp_table :execution_timestamps
  @flush_interval 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Increment the execution count for an organization. Lock-free (ETS atomic update).
  """
  def increment(org_id) do
    :ets.update_counter(@counter_table, org_id, {2, 1}, {org_id, 0})
  end

  @doc """
  Record a task execution timestamp. Only the latest timestamp per task is kept.
  """
  def touch_task(task_id) do
    now = DateTime.utc_now(:second)
    :ets.insert(@timestamp_table, {task_id, now})
  end

  @doc """
  Force an immediate flush of all buffered data to DB. Used in tests.
  """
  def flush_sync do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(_) do
    :ets.new(@counter_table, [:set, :public, :named_table])
    :ets.new(@timestamp_table, [:set, :public, :named_table])
    schedule_flush()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    flush()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    flush()
    schedule_flush()
    {:noreply, state}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defp flush do
    flush_counters()
    flush_timestamps()
  end

  defp flush_counters do
    :ets.tab2list(@counter_table)
    |> Enum.each(fn {org_id, count} ->
      if count > 0 do
        :ets.update_counter(@counter_table, org_id, {2, -count}, {org_id, 0})

        Prikke.Repo.update_all(
          from(o in Prikke.Accounts.Organization, where: o.id == ^org_id),
          inc: [monthly_execution_count: count]
        )
      end
    end)
  end

  defp flush_timestamps do
    entries = :ets.tab2list(@timestamp_table)

    Enum.each(entries, fn {task_id, timestamp} ->
      :ets.delete(@timestamp_table, task_id)

      Prikke.Repo.update_all(
        from(t in Prikke.Tasks.Task, where: t.id == ^task_id),
        set: [last_execution_at: timestamp]
      )
    end)
  end
end
