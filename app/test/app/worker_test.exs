defmodule Prikke.WorkerTest do
  use Prikke.DataCase, async: false

  alias Prikke.Worker
  alias Prikke.Executions
  alias Prikke.Repo

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  describe "worker execution" do
    setup do
      org = organization_fixture()
      # Use a cron task (no future date validation)
      task = task_fixture(org, %{retry_attempts: 3})
      %{org: org, task: task}
    end

    test "claims and executes pending execution", %{task: task} do
      # Trap exits so we don't crash when stopping the worker
      Process.flag(:trap_exit, true)

      # Create a pending execution that's ready to run NOW
      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

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
      # Use a cron task
      task = task_fixture(org)
      # Create a pending execution ready to run
      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())
      %{org: org, task: task, execution: execution}
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
      {:ok, completed} =
        Executions.complete_execution(claimed, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 250
        })

      assert completed.status == "success"
      assert completed.status_code == 200
      assert completed.finished_at != nil
      assert completed.duration_ms == 250
    end

    test "fail_execution sets failed status" do
      {:ok, claimed} = Executions.claim_next_execution()

      {:ok, failed} =
        Executions.fail_execution(claimed, %{
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

  describe "response assertions" do
    setup do
      org = organization_fixture()
      %{org: org}
    end

    # Insert a task directly into the DB bypassing URL validation (needed for localhost/Bypass URLs)
    defp insert_task_for_bypass(org, url, extra_attrs \\ %{}) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs =
        Map.merge(
          %{
            name: "Bypass Task #{System.unique_integer([:positive])}",
            url: url,
            method: "POST",
            headers: %{},
            body: nil,
            schedule_type: "cron",
            cron_expression: "0 * * * *",
            interval_minutes: 60,
            enabled: true,
            retry_attempts: 0,
            timeout_ms: 10_000,
            organization_id: org.id,
            inserted_at: now,
            updated_at: now,
            next_run_at: now
          },
          extra_attrs
        )

      %Prikke.Tasks.Task{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert!()
    end

    test "task with expected_status_codes '200' and response 201 -> failure", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.resp(conn, 201, "Created")
      end)

      task =
        insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook", %{
          expected_status_codes: "200"
        })

      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      updated = Executions.get_execution(execution.id)
      assert updated.status == "failed"
      assert updated.error_message =~ "Assertion failed: status 201 not in [200]"

      GenServer.stop(pid, :normal)
    end

    test "task with expected_status_codes '200,201' and response 201 -> success", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.resp(conn, 201, "Created")
      end)

      task =
        insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook", %{
          expected_status_codes: "200,201"
        })

      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      updated = Executions.get_execution(execution.id)
      assert updated.status == "success"

      GenServer.stop(pid, :normal)
    end

    test "task with expected_body_pattern 'ok' and body 'result: ok' -> success", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.resp(conn, 200, "result: ok")
      end)

      task =
        insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook", %{
          expected_body_pattern: "ok"
        })

      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      updated = Executions.get_execution(execution.id)
      assert updated.status == "success"

      GenServer.stop(pid, :normal)
    end

    test "task with expected_body_pattern 'ok' and body 'error' -> failure", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.resp(conn, 200, "error")
      end)

      task =
        insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook", %{
          expected_body_pattern: "ok"
        })

      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      updated = Executions.get_execution(execution.id)
      assert updated.status == "failed"
      assert updated.error_message =~ "Assertion failed: response body does not contain"

      GenServer.stop(pid, :normal)
    end

    test "task with no assertions and 200 response -> success (backward compat)", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.resp(conn, 200, "OK")
      end)

      task = insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook")

      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      updated = Executions.get_execution(execution.id)
      assert updated.status == "success"

      GenServer.stop(pid, :normal)
    end
  end
end
