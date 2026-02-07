defmodule Prikke.AuditTest do
  use Prikke.DataCase, async: true

  alias Prikke.Audit
  alias Prikke.Accounts.Scope
  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

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
end
