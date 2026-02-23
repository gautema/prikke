defmodule Prikke.QueuesTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures

  alias Prikke.Queues

  describe "pause_queue/2" do
    test "pauses a queue" do
      org = organization_fixture()
      task_fixture(org, %{queue: "emails"})

      assert {:ok, queue} = Queues.pause_queue(org, "emails")
      assert queue.paused == true
      assert queue.name == "emails"
    end

    test "pausing an already paused queue is idempotent" do
      org = organization_fixture()

      {:ok, _} = Queues.pause_queue(org, "emails")
      assert {:ok, queue} = Queues.pause_queue(org, "emails")
      assert queue.paused == true
    end

    test "creates queue record if it doesn't exist" do
      org = organization_fixture()

      assert {:ok, queue} = Queues.pause_queue(org, "new-queue")
      assert queue.name == "new-queue"
      assert queue.paused == true
    end
  end

  describe "resume_queue/2" do
    test "resumes a paused queue" do
      org = organization_fixture()
      Queues.pause_queue(org, "emails")

      assert {:ok, queue} = Queues.resume_queue(org, "emails")
      assert queue.paused == false
    end

    test "resuming a non-existent queue returns :ok" do
      org = organization_fixture()
      assert :ok = Queues.resume_queue(org, "nonexistent")
    end

    test "resuming an already active queue is idempotent" do
      org = organization_fixture()
      Queues.pause_queue(org, "emails")
      Queues.resume_queue(org, "emails")

      assert {:ok, queue} = Queues.resume_queue(org, "emails")
      assert queue.paused == false
    end
  end

  describe "list_paused_queues/1" do
    test "returns empty list when no queues are paused" do
      org = organization_fixture()
      assert Queues.list_paused_queues(org) == []
    end

    test "returns only paused queue names" do
      org = organization_fixture()
      Queues.pause_queue(org, "emails")
      Queues.pause_queue(org, "reports")
      Queues.pause_queue(org, "active-queue")
      Queues.resume_queue(org, "active-queue")

      paused = Queues.list_paused_queues(org)
      assert "emails" in paused
      assert "reports" in paused
      refute "active-queue" in paused
    end

    test "doesn't return paused queues from other orgs" do
      org1 = organization_fixture()
      org2 = organization_fixture()

      Queues.pause_queue(org1, "emails")
      Queues.pause_queue(org2, "reports")

      assert Queues.list_paused_queues(org1) == ["emails"]
      assert Queues.list_paused_queues(org2) == ["reports"]
    end
  end

  describe "queue_paused?/2" do
    test "returns true for paused queue" do
      org = organization_fixture()
      Queues.pause_queue(org, "emails")

      assert Queues.queue_paused?(org, "emails") == true
    end

    test "returns false for active queue" do
      org = organization_fixture()
      Queues.pause_queue(org, "emails")
      Queues.resume_queue(org, "emails")

      assert Queues.queue_paused?(org, "emails") == false
    end

    test "returns false for nonexistent queue" do
      org = organization_fixture()
      assert Queues.queue_paused?(org, "nonexistent") == false
    end
  end

  describe "list_queues_with_status/1" do
    test "returns queues with their status" do
      org = organization_fixture()
      task_fixture(org, %{queue: "emails"})
      task_fixture(org, %{queue: "reports"})
      Queues.pause_queue(org, "emails")

      result = Queues.list_queues_with_status(org)

      assert {"emails", :paused} in result
      assert {"reports", :active} in result
    end

    test "returns empty list when no queues exist" do
      org = organization_fixture()
      assert Queues.list_queues_with_status(org) == []
    end
  end
end
