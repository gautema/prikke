defmodule Prikke.Repo.Migrations.DropUnusedScheduleTypeScheduledAtIndex do
  use Ecto.Migration

  def up do
    # Index was created via raw SQL in partition migration as tasks_schedule_type_scheduled_at_idx
    execute "DROP INDEX IF EXISTS tasks_schedule_type_scheduled_at_idx"
  end

  def down do
    execute """
    CREATE INDEX tasks_schedule_type_scheduled_at_idx
      ON tasks (schedule_type, scheduled_at)
      WHERE schedule_type = 'once'
    """
  end
end
