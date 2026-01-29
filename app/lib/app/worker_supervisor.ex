defmodule Prikke.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor for job execution workers.

  Workers are started and stopped by the WorkerPool based on queue depth.
  Each worker is a transient process that exits normally when idle.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new worker process.
  """
  def start_worker do
    DynamicSupervisor.start_child(__MODULE__, Prikke.Worker)
  end

  @doc """
  Returns the count of active workers.
  """
  def worker_count do
    DynamicSupervisor.count_children(__MODULE__)[:active] || 0
  end
end
