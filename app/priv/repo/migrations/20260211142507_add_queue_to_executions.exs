defmodule Prikke.Repo.Migrations.AddQueueToExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :queue, :string
    end

    # Backfill queue from tasks for active executions
    execute(
      "UPDATE executions SET queue = t.queue FROM tasks t WHERE executions.task_id = t.id AND t.queue IS NOT NULL AND executions.status IN ('pending', 'running')",
      "SELECT 1"
    )

    # Partial index for the blocked_queues query: quickly find running/pending
    # executions that have a queue, scoped by org+queue.
    create index(:executions, [:organization_id, :queue, :status],
      where: "queue IS NOT NULL AND status IN ('running', 'pending')",
      name: :executions_queue_blocking_idx
    )
  end
end
