defmodule Prikke.Repo.Migrations.EndpointFanout do
  use Ecto.Migration

  def up do
    # 1. Add forward_urls array column to endpoints
    alter table(:endpoints) do
      add :forward_urls, {:array, :text}, null: false, default: "{}"
    end

    # 2. Backfill from forward_url
    execute "UPDATE endpoints SET forward_urls = ARRAY[forward_url] WHERE forward_url IS NOT NULL"

    # 3. Drop forward_url
    alter table(:endpoints) do
      remove :forward_url
    end

    # 4. Add task_ids to inbound_events
    alter table(:inbound_events) do
      add :task_ids, {:array, :binary_id}, null: false, default: "{}"
    end

    # 5. Backfill task_ids from execution_id
    execute """
    UPDATE inbound_events ie
    SET task_ids = ARRAY[e.task_id]
    FROM executions e
    WHERE ie.execution_id = e.id AND ie.execution_id IS NOT NULL
    """

    # 6. Drop execution_id
    alter table(:inbound_events) do
      remove :execution_id
    end
  end

  def down do
    # Reverse: add execution_id back
    alter table(:inbound_events) do
      add :execution_id, references(:executions, type: :binary_id, on_delete: :nilify_all)
    end

    # Backfill execution_id from task_ids (take first task's latest execution)
    execute """
    UPDATE inbound_events ie
    SET execution_id = (
      SELECT e.id FROM executions e
      WHERE e.task_id = ie.task_ids[1]
      ORDER BY e.inserted_at ASC
      LIMIT 1
    )
    WHERE array_length(ie.task_ids, 1) > 0
    """

    alter table(:inbound_events) do
      remove :task_ids
    end

    # Reverse: add forward_url back
    alter table(:endpoints) do
      add :forward_url, :text
    end

    execute "UPDATE endpoints SET forward_url = forward_urls[1] WHERE array_length(forward_urls, 1) > 0"

    alter table(:endpoints) do
      remove :forward_urls
    end
  end
end
