defmodule Prikke.AuditTest do
  use Prikke.DataCase, async: true

  alias Prikke.Audit
  alias Prikke.Accounts.Scope
  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures

  describe "log/5" do
    test "creates an audit log for a user action" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      {:ok, log} =
        Audit.log(scope, :created, :job, Ecto.UUID.generate(),
          organization_id: org.id,
          changes: %{"name" => "Test Job"}
        )

      assert log.actor_id == user.id
      assert log.actor_type == "user"
      assert log.action == "created"
      assert log.resource_type == "job"
      assert log.organization_id == org.id
      assert log.changes == %{"name" => "Test Job"}
    end
  end

  describe "log_api/5" do
    test "creates an audit log for an API action" do
      org = organization_fixture()

      {:ok, log} =
        Audit.log_api("my-api-key", :updated, :job, Ecto.UUID.generate(),
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

      Audit.log(scope, :created, :job, Ecto.UUID.generate(), organization_id: org.id)
      Audit.log(scope, :updated, :job, Ecto.UUID.generate(), organization_id: org.id)

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

  describe "integration with Jobs context" do
    test "creates audit log when job is created with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)

      {:ok, job} =
        Prikke.Jobs.create_job(
          org,
          %{
            name: "Test Job",
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
      assert log.resource_type == "job"
      assert log.resource_id == job.id
      assert log.actor_id == user.id
    end

    test "creates audit log when job is updated with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      job = job_fixture(org)

      {:ok, _updated} = Prikke.Jobs.update_job(org, job, %{name: "Updated Name"}, scope: scope)

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "updated"
      assert log.changes["name"]["from"] == job.name
      assert log.changes["name"]["to"] == "Updated Name"
    end

    test "creates audit log when job is deleted with scope" do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      scope = Scope.for_user(user)
      job = job_fixture(org)

      {:ok, _deleted} = Prikke.Jobs.delete_job(org, job, scope: scope)

      logs = Audit.list_organization_logs(org)
      log = hd(logs)
      assert log.action == "deleted"
      assert log.metadata["job_name"] == job.name
    end
  end
end
