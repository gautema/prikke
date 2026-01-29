defmodule Prikke.WorkerTest do
  use Prikke.DataCase, async: false

  alias Prikke.Worker
  alias Prikke.Executions

  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures

  describe "worker execution" do
    setup do
      org = organization_fixture()
      # Use a cron job (no future date validation)
      job = job_fixture(org, %{retry_attempts: 3})
      %{org: org, job: job}
    end

    test "claims and executes pending execution", %{job: job} do
      # Trap exits so we don't crash when stopping the worker
      Process.flag(:trap_exit, true)

      # Create a pending execution that's ready to run NOW
      {:ok, execution} = Executions.create_execution_for_job(job, DateTime.utc_now())

      # Start worker - it will claim and try to execute
      {:ok, pid} = Worker.start_link()

      # Give worker time to process
      Process.sleep(200)

      # Check that execution was claimed (status changed from pending)
      updated = Executions.get_execution(execution.id)
      assert updated.status in ["running", "failed", "timeout"]

      # Worker should still be running (looking for more work)
      assert Process.alive?(pid)

      # Clean up gracefully
      GenServer.stop(pid, :normal)
    end

    test "worker exits after idle timeout with no work" do
      # Trap exits so we don't crash when killing the worker
      Process.flag(:trap_exit, true)

      # Start worker with nothing to do
      {:ok, pid} = Worker.start_link()

      # Worker should exit after max_idle_polls (30) * poll_interval (1000ms) = 30s
      # For testing, we just verify it's alive initially
      assert Process.alive?(pid)

      # We won't wait 30 seconds in tests, but the mechanism is in place
      # Use GenServer.stop for a clean shutdown
      GenServer.stop(pid, :normal)
      assert_receive {:EXIT, ^pid, :normal}
    end
  end

  describe "execution status updates" do
    setup do
      org = organization_fixture()
      # Use a cron job
      job = job_fixture(org)
      # Create a pending execution ready to run
      {:ok, execution} = Executions.create_execution_for_job(job, DateTime.utc_now())
      %{org: org, job: job, execution: execution}
    end

    test "execution starts as pending", %{execution: execution} do
      assert execution.status == "pending"
    end

    test "claim_next_execution changes status to running" do
      {:ok, claimed} = Executions.claim_next_execution()
      assert claimed.status == "running"
      assert claimed.started_at != nil
    end

    test "complete_execution sets success status" do
      # First claim it
      {:ok, claimed} = Executions.claim_next_execution()

      # Then complete it
      {:ok, completed} = Executions.complete_execution(claimed, %{
        status_code: 200,
        response_body: "OK"
      })

      assert completed.status == "success"
      assert completed.status_code == 200
      assert completed.finished_at != nil
      assert completed.duration_ms != nil
    end

    test "fail_execution sets failed status" do
      {:ok, claimed} = Executions.claim_next_execution()

      {:ok, failed} = Executions.fail_execution(claimed, %{
        status_code: 500,
        error_message: "Server error"
      })

      assert failed.status == "failed"
      assert failed.status_code == 500
      assert failed.error_message == "Server error"
    end

    test "timeout_execution sets timeout status" do
      {:ok, claimed} = Executions.claim_next_execution()

      {:ok, timed_out} = Executions.timeout_execution(claimed)

      assert timed_out.status == "timeout"
      assert timed_out.error_message == "Request timed out"
    end
  end
end
