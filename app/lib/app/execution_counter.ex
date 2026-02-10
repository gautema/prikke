defmodule Prikke.ExecutionCounter do
  @moduledoc """
  Buffers monthly execution count increments in ETS and flushes to DB periodically.

  Instead of doing an UPDATE on the organizations row for every single execution,
  we accumulate counts in an ETS table and flush them every few seconds. This
  eliminates row-level lock contention on the organizations table under load.
  """

  use GenServer

  import Ecto.Query, warn: false

  @table :execution_counters
  @flush_interval 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Increment the execution count for an organization. Lock-free (ETS atomic update).
  """
  def increment(org_id) do
    :ets.update_counter(@table, org_id, {2, 1}, {org_id, 0})
  end

  @doc """
  Force an immediate flush of all buffered counts to DB. Used in tests.
  """
  def flush_sync do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table])
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
    :ets.tab2list(@table)
    |> Enum.each(fn {org_id, count} ->
      if count > 0 do
        :ets.update_counter(@table, org_id, {2, -count}, {org_id, 0})

        Prikke.Repo.update_all(
          from(o in Prikke.Accounts.Organization, where: o.id == ^org_id),
          inc: [monthly_execution_count: count]
        )
      end
    end)
  end
end
