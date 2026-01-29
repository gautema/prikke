defmodule Prikke.CleanupTest do
  use Prikke.DataCase, async: false

  alias Prikke.Cleanup
  alias Prikke.Executions

  import Prikke.AccountsFixtures
  import Prikke.JobsFixtures

  describe "cleanup" do
    setup do
      start_supervised!({Cleanup, test_mode: true})
      :ok
    end

    test "deletes executions older than retention period" do
      org = organization_fixture()
      job = job_fixture(org)

      # Create an old execution (8 days ago - older than free tier's 7 days)
      old_time = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      {:ok, old_exec} = Executions.create_execution(%{
        job_id: job.id,
        scheduled_for: old_time
      })
      # Mark it as completed so it has a finished_at
      {:ok, old_exec} = old_exec
        |> Ecto.Changeset.change(%{
          status: "success",
          started_at: old_time,
          finished_at: DateTime.add(old_time, 1, :second)
        })
        |> Prikke.Repo.update()

      # Create a recent execution (1 day ago - within retention)
      recent_time = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
      {:ok, recent_exec} = Executions.create_execution(%{
        job_id: job.id,
        scheduled_for: recent_time
      })
      {:ok, _recent_exec} = recent_exec
        |> Ecto.Changeset.change(%{
          status: "success",
          started_at: recent_time,
          finished_at: DateTime.add(recent_time, 1, :second)
        })
        |> Prikke.Repo.update()

      # Run cleanup
      {:ok, deleted_count} = Cleanup.run_cleanup()

      # Old execution should be deleted
      assert deleted_count == 1
      assert Executions.get_execution(old_exec.id) == nil

      # Recent execution should still exist
      assert Executions.get_execution(recent_exec.id) != nil
    end

    test "respects pro tier's longer retention" do
      org = organization_fixture(%{tier: "pro"})
      job = job_fixture(org)

      # Create an execution 15 days ago (within pro's 30 days)
      old_time = DateTime.utc_now() |> DateTime.add(-15, :day) |> DateTime.truncate(:second)
      {:ok, exec} = Executions.create_execution(%{
        job_id: job.id,
        scheduled_for: old_time
      })
      {:ok, exec} = exec
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
