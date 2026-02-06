defmodule Prikke.MonitorCheckerTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures
  import Prikke.MonitorsFixtures

  alias Prikke.{Monitors, MonitorChecker}

  setup do
    {:ok, pid} = start_supervised({MonitorChecker, test_mode: true})
    Ecto.Adapters.SQL.Sandbox.allow(Prikke.Repo, self(), pid)
    %{checker: pid}
  end

  test "detects overdue monitor and marks as down", %{checker: _checker} do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    monitor = monitor_fixture(org, %{grace_period_seconds: 60})

    # Ping to activate the monitor
    {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

    # Simulate overdue by setting next_expected_at to the past
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    pinged
    |> Ecto.Changeset.change(next_expected_at: past)
    |> Repo.update!()

    # Run the checker
    assert {:ok, 1} = MonitorChecker.check_now()

    # Monitor should be marked as down
    updated = Monitors.get_monitor!(org, monitor.id)
    assert updated.status == "down"
  end

  test "ignores monitors within grace period", %{checker: _checker} do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    monitor = monitor_fixture(org, %{grace_period_seconds: 600})

    # Ping - next_expected_at will be ~1 hour from now, well within grace
    {:ok, _} = Monitors.record_ping!(monitor.ping_token)

    assert {:ok, 0} = MonitorChecker.check_now()

    updated = Monitors.get_monitor!(org, monitor.id)
    assert updated.status == "up"
  end

  test "ignores disabled monitors", %{checker: _checker} do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    monitor = monitor_fixture(org, %{grace_period_seconds: 60})

    {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    pinged
    |> Ecto.Changeset.change(next_expected_at: past, enabled: false)
    |> Repo.update!()

    assert {:ok, 0} = MonitorChecker.check_now()
  end

  test "ignores already down monitors", %{checker: _checker} do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    monitor = monitor_fixture(org, %{grace_period_seconds: 60})

    {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    pinged
    |> Ecto.Changeset.change(next_expected_at: past, status: "down")
    |> Repo.update!()

    assert {:ok, 0} = MonitorChecker.check_now()
  end

  test "ignores new monitors without next_expected_at", %{checker: _checker} do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    _monitor = monitor_fixture(org)

    assert {:ok, 0} = MonitorChecker.check_now()
  end

  test "detects overdue monitor with zero grace period", %{checker: _checker} do
    user = user_fixture()
    {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})
    monitor = monitor_fixture(org, %{interval_seconds: 60, grace_period_seconds: 0})

    # Ping to activate
    {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

    # Set next_expected_at to 2 minutes ago (overdue with 0 grace)
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    pinged
    |> Ecto.Changeset.change(next_expected_at: past)
    |> Repo.update!()

    assert {:ok, 1} = MonitorChecker.check_now()

    updated = Monitors.get_monitor!(org, monitor.id)
    assert updated.status == "down"
  end
end
