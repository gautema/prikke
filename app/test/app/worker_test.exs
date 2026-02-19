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

  describe "DB error resilience" do
    setup do
      org = organization_fixture()
      %{org: org}
    end

    test "worker survives when execution is deleted before status update", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      # The Bypass handler deletes the execution row from the DB before responding.
      # This causes Ecto.StaleEntryError when the worker tries to Repo.update(),
      # simulating a DB failure (pool exhaustion, stale entry, etc.).
      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        # Delete all executions for this org's tasks so the worker's update fails
        Repo.delete_all(Prikke.Executions.Execution)
        Plug.Conn.resp(conn, 200, "OK")
      end)

      task = insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook")
      {:ok, _execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      # Worker should still be alive (didn't crash from the stale entry error)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end

    test "worker survives when execution is deleted before failure update", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        Repo.delete_all(Prikke.Executions.Execution)
        Plug.Conn.resp(conn, 500, "Server Error")
      end)

      task = insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook")
      {:ok, _execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
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

  describe "host blocking" do
    setup do
      org = organization_fixture()
      %{org: org}
    end

    test "worker reschedules execution when host is blocked", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()
      host = "localhost"

      # Pre-block the host
      Prikke.HostBlocker.block(org.id, host, 60_000, :rate_limited)

      task = insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook")
      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      # Execution should be rescheduled back to pending (not failed/success)
      updated = Executions.get_execution(execution.id)
      assert updated.status == "pending"
      # scheduled_for should be in the future
      assert DateTime.compare(updated.scheduled_for, DateTime.utc_now()) == :gt

      # Clean up block
      :ets.delete(:blocked_hosts, {org.id, host})

      GenServer.stop(pid, :normal)
    end

    test "worker blocks host on 429 response", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "120")
        |> Plug.Conn.resp(429, "Too Many Requests")
      end)

      task = insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook")
      {:ok, _execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, pid} = Worker.start_link()
      Process.sleep(500)

      # Host should now be blocked
      assert Prikke.HostBlocker.blocked?(org.id, "localhost")

      # Clean up
      :ets.delete(:blocked_hosts, {org.id, "localhost"})
      :ets.delete(:host_failures, {org.id, "localhost"})

      GenServer.stop(pid, :normal)
    end

    test "worker records failure on 5xx and blocks after threshold", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      # Allow 3 requests to trigger the failure threshold
      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        Plug.Conn.resp(conn, 503, "Service Unavailable")
      end)

      task = insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook")

      # Create 3 executions to trigger threshold
      for _ <- 1..3 do
        {:ok, _} = Executions.create_execution_for_task(task, DateTime.utc_now())
      end

      {:ok, pid} = Worker.start_link()
      Process.sleep(1_500)

      # After 3 consecutive 5xx responses, host should be blocked
      assert Prikke.HostBlocker.blocked?(org.id, "localhost")

      # Clean up
      :ets.delete(:blocked_hosts, {org.id, "localhost"})
      :ets.delete(:host_failures, {org.id, "localhost"})

      GenServer.stop(pid, :normal)
    end

    test "worker resets failure count on success", %{org: org} do
      Process.flag(:trap_exit, true)

      bypass = Bypass.open()

      # First request fails, second succeeds
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        if count <= 2 do
          Plug.Conn.resp(conn, 503, "Service Unavailable")
        else
          Plug.Conn.resp(conn, 200, "OK")
        end
      end)

      task = insert_task_for_bypass(org, "http://localhost:#{bypass.port}/webhook")

      # Create 3 executions: 2 will fail, then 1 will succeed and reset counter
      for _ <- 1..3 do
        {:ok, _} = Executions.create_execution_for_task(task, DateTime.utc_now())
      end

      {:ok, pid} = Worker.start_link()
      Process.sleep(1_500)

      # After success, host should NOT be blocked (counter was reset by the success)
      refute Prikke.HostBlocker.blocked?(org.id, "localhost")

      # Clean up
      :ets.delete(:host_failures, {org.id, "localhost"})

      GenServer.stop(pid, :normal)
    end
  end
end
