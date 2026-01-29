defmodule Prikke.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor for job execution workers.

  Workers are started and stopped by the WorkerPool based on queue depth.
  Each worker is a transient process that exits normally when idle.

  During shutdown, workers are given time to complete their current request
  before being terminated (graceful shutdown).
  """

  use DynamicSupervisor

  # Give workers up to 60 seconds to finish current request during shutdown
  @shutdown_timeout 60_000

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new worker process with graceful shutdown configured.
  """
  def start_worker do
    # Specify child_spec with shutdown timeout for graceful termination
    child_spec = %{
      id: Prikke.Worker,
      start: {Prikke.Worker, :start_link, [[]]},
      restart: :transient,
      shutdown: @shutdown_timeout
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Returns the count of active workers.
  """
  def worker_count do
    DynamicSupervisor.count_children(__MODULE__)[:active] || 0
  end
end
