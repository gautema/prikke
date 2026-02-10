defmodule Prikke.WorkerPoolTest do
  use Prikke.DataCase, async: false

  alias Prikke.WorkerPool
  alias Prikke.WorkerSupervisor
  alias Prikke.Executions

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  describe "worker pool scaling" do
    setup do
      # Start the supervisor fresh for each test
      start_supervised!(WorkerSupervisor)
      start_supervised!({WorkerPool, test_mode: true})
      :ok
    end

    test "scale spawns minimum workers when queue is empty" do
      assert WorkerSupervisor.worker_count() == 0

      {:ok, result} = WorkerPool.scale()

      assert result.queue == 0
      # Should spawn min_workers (1)
      assert result.spawned == 1
      assert WorkerSupervisor.worker_count() == 1
    end

    test "scale spawns workers up to queue depth" do
      org = organization_fixture()
      # Use a cron task (no scheduled_at validation issues)
      task = task_fixture(org)

      # Create 5 pending executions
      for _ <- 1..5 do
        {:ok, _} = Executions.create_execution_for_task(task, DateTime.utc_now())
      end

      {:ok, result} = WorkerPool.scale()

      assert result.queue == 5
      assert result.spawned == 5
      assert WorkerSupervisor.worker_count() == 5
    end

    test "scale respects max_workers limit" do
      org = organization_fixture()
      task = task_fixture(org)

      # Create 60 pending executions (more than max_workers of 50)
      for _ <- 1..60 do
        {:ok, _} = Executions.create_execution_for_task(task, DateTime.utc_now())
      end

      {:ok, result} = WorkerPool.scale()

      assert result.queue == 60
      # Should cap at max_workers (50)
      assert result.spawned == 50
      assert WorkerSupervisor.worker_count() == 50
    end

    test "stats returns current pool state" do
      stats = WorkerPool.stats()

      assert is_integer(stats.queue_depth)
      assert is_integer(stats.active_workers)
      assert stats.min_workers == 1
      assert stats.max_workers == 50
    end
  end

  describe "worker supervisor" do
    setup do
      start_supervised!(WorkerSupervisor)
      :ok
    end

    test "start_worker spawns a worker process" do
      assert WorkerSupervisor.worker_count() == 0

      {:ok, pid} = WorkerSupervisor.start_worker()

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert WorkerSupervisor.worker_count() == 1
    end

    test "workers are supervised and counted" do
      {:ok, pid1} = WorkerSupervisor.start_worker()
      {:ok, _pid2} = WorkerSupervisor.start_worker()

      assert WorkerSupervisor.worker_count() == 2

      # Stop one worker gracefully (normal exit won't trigger restart for transient)
      GenServer.stop(pid1, :normal)
      # Give the supervisor time to notice the process is dead
      Process.sleep(100)

      # Count should decrease
      assert WorkerSupervisor.worker_count() == 1
    end
  end
end
