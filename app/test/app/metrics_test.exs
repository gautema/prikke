defmodule Prikke.MetricsTest do
  use Prikke.DataCase, async: false

  alias Prikke.Metrics

  describe "metrics GenServer" do
    setup do
      start_supervised!({Metrics, test_mode: true})
      :ok
    end

    test "current/0 returns empty map before any samples" do
      assert Metrics.current() == %{}
    end

    test "recent/0 returns empty list before any samples" do
      assert Metrics.recent() == []
    end

    test "alerts/0 returns empty list when healthy" do
      assert Metrics.alerts() == []
    end

    test "sample/0 collects and stores a sample" do
      :ok = Metrics.sample()

      sample = Metrics.current()
      assert is_map(sample)
      assert Map.has_key?(sample, :timestamp)
      assert Map.has_key?(sample, :queue_depth)
      assert Map.has_key?(sample, :active_workers)
      assert Map.has_key?(sample, :beam_memory_mb)
      assert Map.has_key?(sample, :beam_processes)
      assert Map.has_key?(sample, :run_queue)
      assert Map.has_key?(sample, :cpu_percent)
      assert Map.has_key?(sample, :system_memory_used_pct)
      assert Map.has_key?(sample, :disk_usage_pct)
    end

    test "recent/1 returns samples in order" do
      :ok = Metrics.sample()
      :ok = Metrics.sample()
      :ok = Metrics.sample()

      samples = Metrics.recent(3)
      assert length(samples) == 3

      timestamps = Enum.map(samples, & &1.timestamp)

      assert timestamps ==
               Enum.sort(timestamps, fn a, b ->
                 DateTime.compare(a, b) in [:lt, :eq]
               end)
    end

    test "sample values are reasonable" do
      :ok = Metrics.sample()

      sample = Metrics.current()
      assert is_integer(sample.queue_depth)
      assert sample.queue_depth >= 0
      assert is_integer(sample.beam_processes)
      assert sample.beam_processes > 0
      assert is_float(sample.beam_memory_mb)
      assert sample.beam_memory_mb > 0
    end
  end

  describe "historical query functions" do
    import Prikke.AccountsFixtures
    import Prikke.TasksFixtures

    alias Prikke.Executions

    test "get_duration_percentiles/1 returns correct structure with no data" do
      result = Executions.get_duration_percentiles()
      assert result.count == 0
      assert is_nil(result.p50)
      assert is_nil(result.p95)
      assert is_nil(result.p99)
      assert is_nil(result.avg)
    end

    test "get_duration_percentiles/1 with execution data" do
      org = organization_fixture()
      task = task_fixture(org)

      # Create a completed execution
      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, _} =
        Executions.complete_execution(execution, %{
          status_code: 200,
          duration_ms: 250,
          response_body: "ok"
        })

      result = Executions.get_duration_percentiles()
      assert result.count == 1
      assert result.p50 == 250.0
      assert result.avg == Decimal.new("250.0000000000000000")
    end

    test "get_avg_queue_wait/1 returns correct structure with no data" do
      result = Executions.get_avg_queue_wait()
      assert result.count == 0
      assert is_nil(result.avg_wait_ms)
    end

    test "throughput_per_minute/1 returns empty list with no data" do
      result = Executions.throughput_per_minute()
      assert result == []
    end

    test "throughput_per_minute/1 with execution data" do
      org = organization_fixture()
      task = task_fixture(org)

      {:ok, execution} = Executions.create_execution_for_task(task, DateTime.utc_now())

      {:ok, _} =
        Executions.complete_execution(execution, %{
          status_code: 200,
          duration_ms: 100,
          response_body: "ok"
        })

      result = Executions.throughput_per_minute(60)
      assert length(result) >= 1

      {_timestamp, count} = hd(result)
      assert count >= 1
    end

    test "get_scheduling_precision/1 returns correct structure with no data" do
      result = Executions.get_scheduling_precision()
      assert result.count == 0
      assert result.p50 == 0
      assert result.p95 == 0
      assert result.p99 == 0
      assert result.avg == 0
      assert result.max == 0
    end

    test "get_scheduling_precision/1 with execution data" do
      org = organization_fixture()
      task = task_fixture(org)

      now = DateTime.utc_now()
      scheduled_for = DateTime.add(now, -5, :second)

      {:ok, execution} = Executions.create_execution_for_task(task, scheduled_for)

      # Simulate worker claiming the execution (sets started_at)
      {:ok, claimed} =
        execution
        |> Prikke.Executions.Execution.start_changeset()
        |> Prikke.Repo.update()

      {:ok, _} =
        Executions.complete_execution(claimed, %{
          status_code: 200,
          duration_ms: 100,
          response_body: "ok"
        })

      result = Executions.get_scheduling_precision()
      assert result.count == 1
      # Delay should be positive (started_at - scheduled_for ~ 5 seconds = ~5000ms)
      assert result.p95 > 0
    end

    test "get_daily_scheduling_precision/1 returns empty list with no data" do
      result = Executions.get_daily_scheduling_precision()
      assert result == []
    end

    test "aggregate_scheduling_precision/2 stores data and get_daily reads it" do
      org = organization_fixture()
      task = task_fixture(org)

      now = DateTime.utc_now()
      scheduled_for = DateTime.add(now, -2, :second)

      {:ok, execution} = Executions.create_execution_for_task(task, scheduled_for)

      {:ok, claimed} =
        execution
        |> Prikke.Executions.Execution.start_changeset()
        |> Prikke.Repo.update()

      {:ok, _} =
        Executions.complete_execution(claimed, %{
          status_code: 200,
          duration_ms: 100,
          response_body: "ok"
        })

      # Aggregate today's data into the stored table
      count = Executions.aggregate_scheduling_precision(Date.utc_today(), Date.utc_today())
      assert count == 1

      # Verify it's stored in the DB
      alias Prikke.Executions.SchedulingPrecisionDaily
      row = Prikke.Repo.get_by(SchedulingPrecisionDaily, date: Date.utc_today())
      assert row != nil
      assert row.request_count == 1
      assert row.p95_ms > 0
    end

    test "get_daily_scheduling_precision/1 with execution data" do
      org = organization_fixture()
      task = task_fixture(org)

      now = DateTime.utc_now()
      scheduled_for = DateTime.add(now, -3, :second)

      {:ok, execution} = Executions.create_execution_for_task(task, scheduled_for)

      # Simulate worker claiming the execution (sets started_at)
      {:ok, claimed} =
        execution
        |> Prikke.Executions.Execution.start_changeset()
        |> Prikke.Repo.update()

      {:ok, _} =
        Executions.complete_execution(claimed, %{
          status_code: 200,
          duration_ms: 100,
          response_body: "ok"
        })

      result = Executions.get_daily_scheduling_precision(90)
      assert length(result) == 1

      day = hd(result)
      assert day.date == Date.utc_today()
      assert day.count == 1
      assert day.p95 > 0
      assert day.avg > 0
    end
  end
end
