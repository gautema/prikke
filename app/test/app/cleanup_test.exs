defmodule Prikke.CleanupTest do
  use Prikke.DataCase, async: false

  alias Prikke.Cleanup
  alias Prikke.Executions

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  describe "run_monthly_summary/0" do
    setup do
      # Configure admin_email for tests
      original = Application.get_env(:app, Prikke.Mailer)

      Application.put_env(
        :app,
        Prikke.Mailer,
        Keyword.put(original, :admin_email, "admin@test.com")
      )

      on_exit(fn ->
        Application.put_env(:app, Prikke.Mailer, original)
      end)

      :ok
    end

    test "sends monthly summary email" do
      assert :ok = Cleanup.run_monthly_summary()
    end

    test "email is logged with correct type" do
      Cleanup.run_monthly_summary()

      emails = Prikke.Emails.list_recent_emails(limit: 1)
      assert length(emails) == 1
      assert hd(emails).email_type == "monthly_summary"
      assert hd(emails).to == "admin@test.com"
    end
  end

  describe "cleanup" do
    setup do
      start_supervised!({Cleanup, test_mode: true})
      :ok
    end

    test "deletes executions older than retention period" do
      org = organization_fixture()
      task = task_fixture(org)

      # Create an old execution (8 days ago - older than free tier's 7 days)
      old_time = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)

      {:ok, old_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          scheduled_for: old_time
        })

      # Mark it as completed so it has a finished_at
      {:ok, old_exec} =
        old_exec
        |> Ecto.Changeset.change(%{
          status: "success",
          started_at: old_time,
          finished_at: DateTime.add(old_time, 1, :second)
        })
        |> Prikke.Repo.update()

      # Create a recent execution (1 day ago - within retention)
      recent_time = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      {:ok, recent_exec} =
        Executions.create_execution(%{
          task_id: task.id,
          scheduled_for: recent_time
        })

      {:ok, _recent_exec} =
        recent_exec
        |> Ecto.Changeset.change(%{
          status: "success",
          started_at: recent_time,
          finished_at: DateTime.add(recent_time, 1, :second)
        })
        |> Prikke.Repo.update()

      # Run cleanup
      {:ok, result} = Cleanup.run_cleanup()

      # Old execution should be deleted
      assert result.executions == 1
      assert Executions.get_execution(old_exec.id) == nil

      # Recent execution should still exist
      assert Executions.get_execution(recent_exec.id) != nil
    end

    test "deletes completed one-time tasks older than retention period" do
      org = organization_fixture()

      # Create one-time tasks first with future dates, then backdate them
      future = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
      old_time = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      recent_time = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      # Create and then backdate to simulate an old completed one-time task
      old_task = task_fixture(org, %{schedule_type: "once", scheduled_at: future})

      old_task
      |> Ecto.Changeset.change(%{next_run_at: nil, updated_at: old_time, scheduled_at: old_time})
      |> Prikke.Repo.update!()

      # Create and then backdate to simulate a recent completed one-time task
      recent_task = task_fixture(org, %{schedule_type: "once", scheduled_at: future})

      recent_task
      |> Ecto.Changeset.change(%{
        next_run_at: nil,
        updated_at: recent_time,
        scheduled_at: recent_time
      })
      |> Prikke.Repo.update!()

      # Create a cron task (should not be deleted)
      cron_task = task_fixture(org, %{schedule_type: "cron", cron_expression: "0 * * * *"})

      # Run cleanup
      {:ok, result} = Cleanup.run_cleanup()

      # Only old completed one-time task should be deleted
      assert result.tasks == 1
      assert Prikke.Tasks.get_task(org, old_task.id) == nil
      assert Prikke.Tasks.get_task(org, recent_task.id) != nil
      assert Prikke.Tasks.get_task(org, cron_task.id) != nil
    end

    test "respects pro tier's longer retention" do
      org = organization_fixture(%{tier: "pro"})
      task = task_fixture(org)

      # Create an execution 15 days ago (within pro's 30 days)
      old_time = DateTime.utc_now() |> DateTime.add(-15, :day) |> DateTime.truncate(:second)

      {:ok, exec} =
        Executions.create_execution(%{
          task_id: task.id,
          scheduled_for: old_time
        })

      {:ok, exec} =
        exec
        |> Ecto.Changeset.change(%{
          status: "success",
          started_at: old_time,
          finished_at: DateTime.add(old_time, 1, :second)
        })
        |> Prikke.Repo.update()

      # Run cleanup
      {:ok, _} = Cleanup.run_cleanup()

      # Execution should still exist (within 30-day retention)
      assert Executions.get_execution(exec.id) != nil
    end
  end
end
