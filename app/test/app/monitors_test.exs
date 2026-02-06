defmodule Prikke.MonitorsTest do
  use Prikke.DataCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.MonitorsFixtures

  alias Prikke.Monitors
  alias Prikke.Accounts

  describe "list_monitors/1" do
    test "returns monitors scoped to organization" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Org 1"})
      {:ok, org2} = Accounts.create_organization(user, %{name: "Org 2"})

      m1 = monitor_fixture(org, %{name: "Monitor 1"})
      _m2 = monitor_fixture(org2, %{name: "Monitor 2"})

      monitors = Monitors.list_monitors(org)
      assert length(monitors) == 1
      assert hd(monitors).id == m1.id
    end
  end

  describe "get_monitor!/2" do
    test "returns monitor for org" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)

      found = Monitors.get_monitor!(org, monitor.id)
      assert found.id == monitor.id
    end

    test "raises for wrong org" do
      user = user_fixture()
      {:ok, org1} = Accounts.create_organization(user, %{name: "Org 1"})
      {:ok, org2} = Accounts.create_organization(user, %{name: "Org 2"})
      monitor = monitor_fixture(org1)

      assert_raise Ecto.NoResultsError, fn ->
        Monitors.get_monitor!(org2, monitor.id)
      end
    end
  end

  describe "create_monitor/3" do
    test "creates interval monitor" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      assert {:ok, monitor} =
               Monitors.create_monitor(org, %{
                 name: "Heartbeat",
                 schedule_type: "interval",
                 interval_seconds: 3600,
                 grace_period_seconds: 300
               })

      assert monitor.name == "Heartbeat"
      assert monitor.schedule_type == "interval"
      assert monitor.interval_seconds == 3600
      assert monitor.status == "new"
      assert monitor.enabled == true
      assert String.starts_with?(monitor.ping_token, "pm_")
    end

    test "creates cron monitor" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      assert {:ok, monitor} =
               Monitors.create_monitor(org, %{
                 name: "Daily Check",
                 schedule_type: "cron",
                 cron_expression: "0 9 * * *"
               })

      assert monitor.cron_expression == "0 9 * * *"
    end

    test "validates invalid cron expression" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      assert {:error, changeset} =
               Monitors.create_monitor(org, %{
                 name: "Bad Cron",
                 schedule_type: "cron",
                 cron_expression: "not a cron"
               })

      assert errors_on(changeset).cron_expression
    end

    test "requires interval_seconds for interval type" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      assert {:error, changeset} =
               Monitors.create_monitor(org, %{
                 name: "Missing Interval",
                 schedule_type: "interval"
               })

      assert errors_on(changeset).interval_seconds
    end

    test "enforces tier limit for free plan" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})

      # Free plan allows 3 monitors
      for i <- 1..3 do
        {:ok, _} =
          Monitors.create_monitor(org, %{
            name: "Monitor #{i}",
            schedule_type: "interval",
            interval_seconds: 3600
          })
      end

      assert {:error, changeset} =
               Monitors.create_monitor(org, %{
                 name: "Monitor 4",
                 schedule_type: "interval",
                 interval_seconds: 3600
               })

      assert errors_on(changeset).base
    end

    test "pro plan has unlimited monitors" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Pro Org"})
      {:ok, org} = Accounts.upgrade_organization_to_pro(org)

      for i <- 1..5 do
        {:ok, _} =
          Monitors.create_monitor(org, %{
            name: "Monitor #{i}",
            schedule_type: "interval",
            interval_seconds: 3600
          })
      end

      assert Monitors.count_monitors(org) == 5
    end
  end

  describe "delete_monitor/3" do
    test "deletes monitor" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)

      assert {:ok, _} = Monitors.delete_monitor(org, monitor)
      assert Monitors.count_monitors(org) == 0
    end
  end

  describe "toggle_monitor/3" do
    test "disables monitor and sets status to paused" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)

      assert {:ok, updated} = Monitors.toggle_monitor(org, monitor)
      assert updated.enabled == false
      assert updated.status == "paused"
    end

    test "enables paused monitor and sets status to new" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)
      {:ok, disabled} = Monitors.toggle_monitor(org, monitor)

      assert {:ok, enabled} = Monitors.toggle_monitor(org, disabled)
      assert enabled.enabled == true
      assert enabled.status == "new"
    end
  end

  describe "record_ping!/1" do
    test "transitions new monitor to up" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)
      assert monitor.status == "new"

      assert {:ok, updated} = Monitors.record_ping!(monitor.ping_token)
      assert updated.status == "up"
      assert updated.last_ping_at != nil
      assert updated.next_expected_at != nil
    end

    test "updates timestamps on subsequent pings" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)

      {:ok, first} = Monitors.record_ping!(monitor.ping_token)
      {:ok, second} = Monitors.record_ping!(monitor.ping_token)

      assert DateTime.compare(second.last_ping_at, first.last_ping_at) in [:gt, :eq]
    end

    test "returns error for unknown token" do
      assert {:error, :not_found} = Monitors.record_ping!("pm_nonexistent")
    end

    test "returns error for disabled monitor" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)
      {:ok, disabled} = Monitors.toggle_monitor(org, monitor)

      assert {:error, :disabled} = Monitors.record_ping!(disabled.ping_token)
    end

    test "creates ping record" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)

      {:ok, _} = Monitors.record_ping!(monitor.ping_token)

      pings = Monitors.list_recent_pings(monitor)
      assert length(pings) == 1
    end

    test "computes next_expected_at for interval monitor" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org, %{interval_seconds: 3600})

      {:ok, updated} = Monitors.record_ping!(monitor.ping_token)

      # next_expected should be ~1 hour from now
      diff = DateTime.diff(updated.next_expected_at, updated.last_ping_at)
      assert diff == 3600
    end

    test "computes next_expected_at for cron monitor" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = cron_monitor_fixture(org, %{cron_expression: "0 * * * *"})

      {:ok, updated} = Monitors.record_ping!(monitor.ping_token)

      assert updated.next_expected_at != nil
      # next expected should be the next hour mark
      assert updated.next_expected_at.minute == 0
    end
  end

  describe "find_overdue_monitors/0" do
    test "finds monitors past their expected time + grace period" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org, %{grace_period_seconds: 60})

      # Simulate: ping received, then time passes beyond grace
      {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

      # Manually set next_expected_at to the past
      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      pinged
      |> Ecto.Changeset.change(next_expected_at: past)
      |> Repo.update!()

      overdue = Monitors.find_overdue_monitors()
      assert length(overdue) == 1
      assert hd(overdue).id == monitor.id
    end

    test "ignores monitors within grace period" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org, %{grace_period_seconds: 600})

      {:ok, _} = Monitors.record_ping!(monitor.ping_token)

      overdue = Monitors.find_overdue_monitors()
      assert overdue == []
    end

    test "ignores disabled monitors" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org, %{grace_period_seconds: 60})

      {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      pinged
      |> Ecto.Changeset.change(next_expected_at: past, enabled: false)
      |> Repo.update!()

      overdue = Monitors.find_overdue_monitors()
      assert overdue == []
    end

    test "ignores already down monitors" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org, %{grace_period_seconds: 60})

      {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      pinged
      |> Ecto.Changeset.change(next_expected_at: past, status: "down")
      |> Repo.update!()

      overdue = Monitors.find_overdue_monitors()
      assert overdue == []
    end

    test "ignores monitors with no next_expected_at" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      _monitor = monitor_fixture(org)

      # New monitors have no next_expected_at
      overdue = Monitors.find_overdue_monitors()
      assert overdue == []
    end
  end

  describe "mark_down!/1" do
    test "sets status to down" do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test Org"})
      monitor = monitor_fixture(org)
      {:ok, pinged} = Monitors.record_ping!(monitor.ping_token)

      assert {:ok, downed} = Monitors.mark_down!(pinged)
      assert downed.status == "down"
    end
  end
end
