defmodule Prikke.AuditTest do
  use Prikke.DataCase, async: true

  alias Prikke.Audit
  alias Prikke.Accounts.Scope
  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.StatusPagesFixtures

  describe "log/5" do
    test "creates an audit log for a user action" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      {:ok, log} =
        Audit.log(scope, :created, :task, Ecto.UUID.generate(),
          organization_id: org.id,
          changes: %{"name" => "Test Task"}
        )

      assert log.actor_id == user.id
      assert log.actor_type == "user"
      assert log.action == "created"
      assert log.resource_type == "task"
      assert log.organization_id == org.id
      assert log.changes == %{"name" => "Test Task"}
    end
  end

  describe "log_api/5" do
    test "creates an audit log for an API action" do
      org = organization_fixture()

      {:ok, log} =
        Audit.log_api("my-api-key", :updated, :task, Ecto.UUID.generate(),
          organization_id: org.id,
          changes: %{"enabled" => %{"from" => false, "to" => true}}
        )

      assert log.actor_id == nil
      assert log.actor_type == "api"
      assert log.action == "updated"
      assert log.metadata["api_key_name"] == "my-api-key"
    end
  end

  describe "log_system/4" do
    test "creates an audit log for a system action" do
      {:ok, log} = Audit.log_system(:deleted, :execution, Ecto.UUID.generate())

      assert log.actor_id == nil
      assert log.actor_type == "system"
      assert log.action == "deleted"
    end
  end

  describe "list_organization_logs/2" do
    test "lists audit logs for an organization" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      Audit.log(scope, :created, :task, Ecto.UUID.generate(), organization_id: org.id)
      Audit.log(scope, :updated, :task, Ecto.UUID.generate(), organization_id: org.id)

      logs = Audit.list_organization_logs(org)
      assert length(logs) == 2
    end
  end

  describe "compute_changes/3" do
    test "computes changes between old and new maps" do
      old = %{name: "Old Name", enabled: true, url: "https://example.com"}
      new = %{name: "New Name", enabled: true, url: "https://newurl.com"}

      changes = Audit.compute_changes(old, new, [:name, :enabled, :url])

      assert changes == %{
               "name" => %{"from" => "Old Name", "to" => "New Name"},
               "url" => %{"from" => "https://example.com", "to" => "https://newurl.com"}
             }
    end

    test "excludes unchanged fields" do
      old = %{name: "Same", enabled: true}
      new = %{name: "Same", enabled: false}

      changes = Audit.compute_changes(old, new, [:name, :enabled])

      assert changes == %{
               "enabled" => %{"from" => true, "to" => false}
             }
    end
  end

  describe "integration with Tasks context" do
    test "creates audit log when task is created with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      {:ok, task} =
        Prikke.Tasks.create_task(
          org,
          %{
            name: "Test Task",
            url: "https://example.com/webhook",
            schedule_type: "cron",
            cron_expression: "0 * * * *"
          },
          scope: scope
        )

      logs = Audit.list_organization_logs(org)
      assert length(logs) == 1

      log = hd(logs)
      assert log.action == "created"
      assert log.resource_type == "task"
      assert log.resource_id == task.id
      assert log.actor_id == user.id
    end

    test "creates audit log when task is updated with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      task = task_fixture(org)

      {:ok, _updated} = Prikke.Tasks.update_task(org, task, %{name: "Updated Name"}, scope: scope)

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "updated"
      assert log.changes["name"]["from"] == task.name
      assert log.changes["name"]["to"] == "Updated Name"
    end

    test "creates audit log when task is deleted with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      task = task_fixture(org)

      {:ok, _deleted} = Prikke.Tasks.delete_task(org, task, scope: scope)

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "deleted"
      assert log.metadata["task_name"] == task.name
    end
  end

  describe "integration with Monitors context" do
    test "creates audit log when monitor is created with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      {:ok, monitor} =
        Prikke.Monitors.create_monitor(
          org,
          %{
            name: "Test Monitor",
            schedule_type: "interval",
            interval_seconds: 3600,
            grace_period_seconds: 300
          },
          scope: scope
        )

      logs = Audit.list_organization_logs(org)
      assert length(logs) == 1

      log = hd(logs)
      assert log.action == "created"
      assert log.resource_type == "monitor"
      assert log.resource_id == monitor.id
      assert log.actor_id == user.id
      assert log.metadata["monitor_name"] == "Test Monitor"
    end

    test "creates audit log when monitor is updated with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      monitor = monitor_fixture(org)

      {:ok, _updated} =
        Prikke.Monitors.update_monitor(org, monitor, %{name: "Updated Monitor"}, scope: scope)

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "updated"
      assert log.resource_type == "monitor"
      assert log.changes["name"]["from"] == monitor.name
      assert log.changes["name"]["to"] == "Updated Monitor"
    end

    test "creates audit log when monitor is deleted with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      monitor = monitor_fixture(org)

      {:ok, _deleted} = Prikke.Monitors.delete_monitor(org, monitor, scope: scope)

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "deleted"
      assert log.resource_type == "monitor"
      assert log.metadata["monitor_name"] == monitor.name
    end

    test "creates audit log when monitor is toggled with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      monitor = monitor_fixture(org, %{enabled: true})

      {:ok, _disabled} = Prikke.Monitors.toggle_monitor(org, monitor, scope: scope)

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "disabled"
      assert log.resource_type == "monitor"
      assert log.metadata["monitor_name"] == monitor.name
    end

    test "logs enabled when toggling a disabled monitor" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      monitor = monitor_fixture(org, %{enabled: true})

      # First disable it
      {:ok, disabled} = Prikke.Monitors.toggle_monitor(org, monitor, scope: scope)
      # Then enable it
      {:ok, _enabled} = Prikke.Monitors.toggle_monitor(org, disabled, scope: scope)

      logs = Audit.list_organization_logs(org)
      actions = Enum.map(logs, & &1.action) |> Enum.sort()
      assert actions == ["disabled", "enabled"]
    end

    test "does not create audit log when no scope is provided" do
      org = organization_fixture()
      monitor = monitor_fixture(org)

      {:ok, _updated} = Prikke.Monitors.update_monitor(org, monitor, %{name: "No Audit"})

      logs = Audit.list_organization_logs(org)
      assert logs == []
    end
  end

  describe "integration with StatusPages" do
    test "creates audit log when status page is updated via LiveView" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      status_page = status_page_fixture(org, %{title: "Old Title", enabled: false})

      # Simulate what the LiveView does
      old = status_page
      {:ok, updated} = Prikke.StatusPages.update_status_page(status_page, %{title: "New Title"})
      changes = Audit.compute_changes(old, updated, [:title, :slug, :description, :enabled])

      Audit.log(scope, :updated, :status_page, updated.id,
        organization_id: org.id,
        changes: changes
      )

      logs = Audit.list_organization_logs(org)
      assert length(logs) == 1

      log = hd(logs)
      assert log.action == "updated"
      assert log.resource_type == "status_page"
      assert log.changes["title"]["from"] == "Old Title"
      assert log.changes["title"]["to"] == "New Title"
    end

    test "creates audit log when status page is enabled" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      status_page = status_page_fixture(org, %{enabled: false})

      old = status_page
      {:ok, updated} = Prikke.StatusPages.update_status_page(status_page, %{enabled: true})
      changes = Audit.compute_changes(old, updated, [:title, :slug, :description, :enabled])

      Audit.log(scope, :updated, :status_page, updated.id,
        organization_id: org.id,
        changes: changes
      )

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.changes["enabled"]["from"] == false
      assert log.changes["enabled"]["to"] == true
    end

    test "does not create audit log when nothing changed" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      status_page = status_page_fixture(org, %{title: "Same Title"})

      old = status_page
      {:ok, updated} = Prikke.StatusPages.update_status_page(status_page, %{title: "Same Title"})
      changes = Audit.compute_changes(old, updated, [:title, :slug, :description, :enabled])

      # The LiveView checks this before logging
      assert changes == %{}
    end

    test "creates audit log for badge enable/disable" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      task = task_fixture(org)

      Audit.log(scope, :enabled, :status_page_badge, task.id,
        organization_id: org.id,
        metadata: %{"resource_type" => "task", "resource_name" => task.name}
      )

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "enabled"
      assert log.resource_type == "status_page_badge"
      assert log.metadata["resource_type"] == "task"
      assert log.metadata["resource_name"] == task.name
    end
  end

  describe "integration with Invites" do
    test "creates audit log when invite is sent" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      {:ok, invite, _raw_token} =
        Prikke.Accounts.create_organization_invite(org, user, %{
          email: "invited@example.com",
          role: "member"
        })

      Audit.log(scope, :invited, :invite, invite.id,
        organization_id: org.id,
        metadata: %{"email" => "invited@example.com", "role" => "member"}
      )

      logs = Audit.list_organization_logs(org)
      assert length(logs) == 1

      log = hd(logs)
      assert log.action == "invited"
      assert log.resource_type == "invite"
      assert log.metadata["email"] == "invited@example.com"
      assert log.metadata["role"] == "member"
    end

    test "creates audit log when invite is cancelled" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      {:ok, invite, _raw_token} =
        Prikke.Accounts.create_organization_invite(org, user, %{
          email: "cancelled@example.com",
          role: "member"
        })

      Prikke.Accounts.delete_invite(invite)

      Audit.log(scope, :deleted, :invite, invite.id,
        organization_id: org.id,
        metadata: %{"email" => "cancelled@example.com"}
      )

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "deleted"
      assert log.resource_type == "invite"
      assert log.metadata["email"] == "cancelled@example.com"
    end
  end
end
