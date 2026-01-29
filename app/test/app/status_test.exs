defmodule Prikke.StatusTest do
  use Prikke.DataCase

  alias Prikke.Status

  describe "upsert_check/3" do
    test "creates a new check if it doesn't exist" do
      assert {:ok, check, :created} = Status.upsert_check("scheduler", "up", "Running")

      assert check.component == "scheduler"
      assert check.status == "up"
      assert check.message == "Running"
      assert check.started_at
      assert check.last_checked_at
    end

    test "updates existing check and returns :updated when status unchanged" do
      {:ok, _check, :created} = Status.upsert_check("scheduler", "up", "Running")
      :timer.sleep(10)

      {:ok, updated, :updated} = Status.upsert_check("scheduler", "up", "Still running")

      assert updated.message == "Still running"
      assert updated.status == "up"
    end

    test "returns :status_changed when status changes" do
      {:ok, _check, :created} = Status.upsert_check("scheduler", "up", "Running")

      {:ok, updated, :status_changed} = Status.upsert_check("scheduler", "down", "Crashed")

      assert updated.status == "down"
      assert updated.message == "Crashed"
      assert updated.last_status_change_at
    end
  end

  describe "get_current_status/0" do
    test "returns all component statuses" do
      {:ok, _, _} = Status.upsert_check("scheduler", "up", "Running")
      {:ok, _, _} = Status.upsert_check("workers", "up", "Workers OK")
      {:ok, _, _} = Status.upsert_check("api", "up", "API OK")

      status = Status.get_current_status()

      assert Map.has_key?(status, "scheduler")
      assert Map.has_key?(status, "workers")
      assert Map.has_key?(status, "api")
      assert status["scheduler"].status == "up"
    end
  end

  describe "overall_status/0" do
    test "returns operational when all components are up" do
      {:ok, _, _} = Status.upsert_check("scheduler", "up", "Running")
      {:ok, _, _} = Status.upsert_check("workers", "up", "Workers OK")
      {:ok, _, _} = Status.upsert_check("api", "up", "API OK")

      assert Status.overall_status() == "operational"
    end

    test "returns degraded when any component is degraded" do
      {:ok, _, _} = Status.upsert_check("scheduler", "up", "Running")
      {:ok, _, _} = Status.upsert_check("workers", "degraded", "Slow")
      {:ok, _, _} = Status.upsert_check("api", "up", "API OK")

      assert Status.overall_status() == "degraded"
    end

    test "returns down when any component is down" do
      {:ok, _, _} = Status.upsert_check("scheduler", "up", "Running")
      {:ok, _, _} = Status.upsert_check("workers", "down", "Dead")
      {:ok, _, _} = Status.upsert_check("api", "up", "API OK")

      assert Status.overall_status() == "down"
    end
  end

  describe "incidents" do
    test "create_incident/3 creates an incident" do
      {:ok, incident} = Status.create_incident("scheduler", "down", "Process crashed")

      assert incident.component == "scheduler"
      assert incident.status == "down"
      assert incident.message == "Process crashed"
      assert incident.started_at
      assert is_nil(incident.resolved_at)
    end

    test "resolve_incident/1 marks incident as resolved" do
      {:ok, incident} = Status.create_incident("scheduler", "down", "Crashed")
      {:ok, resolved} = Status.resolve_incident(incident)

      assert resolved.resolved_at
    end

    test "get_open_incident/1 returns open incident for component" do
      {:ok, _incident} = Status.create_incident("scheduler", "down", "Crashed")

      open = Status.get_open_incident("scheduler")
      assert open
      assert open.component == "scheduler"
      assert is_nil(open.resolved_at)
    end

    test "get_open_incident/1 returns nil when no open incident" do
      assert is_nil(Status.get_open_incident("scheduler"))
    end

    test "list_open_incidents/0 returns all open incidents" do
      {:ok, _} = Status.create_incident("scheduler", "down", "Crashed")
      {:ok, incident2} = Status.create_incident("workers", "down", "Dead")
      Status.resolve_incident(incident2)

      open = Status.list_open_incidents()
      assert length(open) == 1
      assert hd(open).component == "scheduler"
    end

    test "list_recent_incidents/1 returns resolved incidents" do
      {:ok, incident1} = Status.create_incident("scheduler", "down", "Crashed")
      Status.resolve_incident(incident1)
      {:ok, _incident2} = Status.create_incident("workers", "down", "Dead")

      recent = Status.list_recent_incidents(10)
      # Only resolved incidents
      assert length(recent) == 1
      assert hd(recent).component == "scheduler"
    end
  end
end
