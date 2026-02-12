defmodule Prikke.Repo.Migrations.AddOrgFairnessIndex do
  use Ecto.Migration

  def change do
    # Partial index for org fairness filter: quickly count running executions per org.
    # Only indexes rows with status='running' (typically 0-20 rows), so it's tiny.
    create index(:executions, [:organization_id],
      where: "status = 'running'",
      name: :executions_running_org_idx
    )
  end
end
