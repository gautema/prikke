defmodule Prikke.Repo.Migrations.CreateStatusPageItems do
  use Ecto.Migration

  def up do
    create table(:status_page_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status_page_id, references(:status_pages, type: :binary_id, on_delete: :delete_all), null: false
      add :resource_type, :text, null: false
      add :resource_id, :binary_id, null: false
      add :badge_token, :text, null: false
      add :position, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:status_page_items, [:badge_token])
    create unique_index(:status_page_items, [:status_page_id, :resource_type, :resource_id])

    # Migrate existing badge_token data from tasks, monitors, endpoints
    execute """
    INSERT INTO status_page_items (id, status_page_id, resource_type, resource_id, badge_token, position, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      sp.id,
      'task',
      t.id,
      t.badge_token,
      0,
      NOW(),
      NOW()
    FROM tasks t
    JOIN organizations o ON t.organization_id = o.id
    JOIN status_pages sp ON sp.organization_id = o.id
    WHERE t.badge_token IS NOT NULL AND t.deleted_at IS NULL
    """

    execute """
    INSERT INTO status_page_items (id, status_page_id, resource_type, resource_id, badge_token, position, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      sp.id,
      'monitor',
      m.id,
      m.badge_token,
      0,
      NOW(),
      NOW()
    FROM monitors m
    JOIN organizations o ON m.organization_id = o.id
    JOIN status_pages sp ON sp.organization_id = o.id
    WHERE m.badge_token IS NOT NULL
    """

    execute """
    INSERT INTO status_page_items (id, status_page_id, resource_type, resource_id, badge_token, position, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      sp.id,
      'endpoint',
      e.id,
      e.badge_token,
      0,
      NOW(),
      NOW()
    FROM endpoints e
    JOIN organizations o ON e.organization_id = o.id
    JOIN status_pages sp ON sp.organization_id = o.id
    WHERE e.badge_token IS NOT NULL
    """

    # Drop badge_token columns and their indexes
    drop_if_exists index(:tasks, [:badge_token])
    drop_if_exists index(:monitors, [:badge_token])
    drop_if_exists index(:endpoints, [:badge_token])

    alter table(:tasks) do
      remove :badge_token
    end

    alter table(:monitors) do
      remove :badge_token
    end

    alter table(:endpoints) do
      remove :badge_token
    end
  end

  def down do
    alter table(:tasks) do
      add :badge_token, :text
    end

    alter table(:monitors) do
      add :badge_token, :text
    end

    alter table(:endpoints) do
      add :badge_token, :text
    end

    execute """
    UPDATE tasks SET badge_token = spi.badge_token
    FROM status_page_items spi
    WHERE spi.resource_type = 'task' AND spi.resource_id = tasks.id
    """

    execute """
    UPDATE monitors SET badge_token = spi.badge_token
    FROM status_page_items spi
    WHERE spi.resource_type = 'monitor' AND spi.resource_id = monitors.id
    """

    execute """
    UPDATE endpoints SET badge_token = spi.badge_token
    FROM status_page_items spi
    WHERE spi.resource_type = 'endpoint' AND spi.resource_id = endpoints.id
    """

    create unique_index(:tasks, [:badge_token], where: "badge_token IS NOT NULL")
    create unique_index(:monitors, [:badge_token], where: "badge_token IS NOT NULL")
    create unique_index(:endpoints, [:badge_token], where: "badge_token IS NOT NULL")

    drop table(:status_page_items)
  end
end
