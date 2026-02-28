defmodule Prikke.StatusPages do
  @moduledoc """
  The StatusPages context for customer-facing public status pages.

  Each organization can have one status page that displays the status
  of their badge-enabled tasks, monitors, endpoints, and queues.

  Resource visibility is managed through `StatusPageItem` records in the
  `status_page_items` join table, which centralizes badge management.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.StatusPages.StatusPage
  alias Prikke.StatusPages.StatusPageItem
  alias Prikke.Accounts.Organization

  @doc """
  Gets or creates a status page for the organization.

  If no status page exists, creates one with defaults:
  - Title: organization name
  - Slug: slugified organization name
  - Enabled: false
  """
  def get_or_create_status_page(%Organization{} = org) do
    case get_status_page(org) do
      nil ->
        slug = slugify(org.name)

        %StatusPage{}
        |> StatusPage.create_changeset(
          %{title: org.name, slug: slug, enabled: false},
          org.id
        )
        |> Repo.insert()

      status_page ->
        {:ok, status_page}
    end
  end

  @doc """
  Gets the status page for an organization, or nil if none exists.
  """
  def get_status_page(%Organization{} = org) do
    Repo.one(from sp in StatusPage, where: sp.organization_id == ^org.id)
  end

  @doc """
  Updates a status page's settings.
  """
  def update_status_page(%StatusPage{} = status_page, attrs) do
    status_page
    |> StatusPage.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns a changeset for tracking status page changes.
  """
  def change_status_page(%StatusPage{} = status_page, attrs \\ %{}) do
    StatusPage.changeset(status_page, attrs)
  end

  @doc """
  Gets a public status page by slug. Returns nil if not found or disabled.
  """
  def get_public_status_page(slug) do
    Repo.one(
      from sp in StatusPage,
        where: sp.slug == ^slug and sp.enabled == true,
        preload: [:organization]
    )
  end

  @doc """
  Gets a status page by slug regardless of enabled status. For previewing.
  """
  def get_status_page_by_slug(slug) do
    Repo.one(from sp in StatusPage, where: sp.slug == ^slug, preload: [:organization])
  end

  # -- Status Page Items --

  @doc """
  Adds a resource to the status page, generating a badge token.
  Returns {:ok, item} or {:error, changeset}.
  """
  def add_item(%StatusPage{} = status_page, resource_type, resource_id)
      when resource_type in ["task", "monitor", "endpoint", "queue"] do
    %StatusPageItem{}
    |> StatusPageItem.create_changeset(
      %{
        resource_type: resource_type,
        resource_id: resource_id,
        badge_token: Prikke.Badges.generate_token()
      },
      status_page.id
    )
    |> Repo.insert()
  end

  @doc """
  Removes a resource from the status page.
  Returns {:ok, item} or {:error, :not_found}.
  """
  def remove_item(%StatusPage{} = status_page, resource_type, resource_id) do
    case Repo.one(
           from i in StatusPageItem,
             where:
               i.status_page_id == ^status_page.id and
                 i.resource_type == ^resource_type and
                 i.resource_id == ^resource_id
         ) do
      nil -> {:error, :not_found}
      item -> Repo.delete(item)
    end
  end

  @doc """
  Gets a status page item by its badge token. Returns nil if not found.
  """
  def get_item_by_badge_token(nil), do: nil

  def get_item_by_badge_token(token) do
    Repo.one(from i in StatusPageItem, where: i.badge_token == ^token)
  end

  @doc """
  Lists all items for a status page, ordered by position then resource type.
  """
  def list_items(%StatusPage{} = status_page) do
    from(i in StatusPageItem,
      where: i.status_page_id == ^status_page.id,
      order_by: [asc: i.position, asc: i.resource_type]
    )
    |> Repo.all()
  end

  @doc """
  Gets the status page item for a specific resource, if it exists.
  """
  def get_item(%StatusPage{} = status_page, resource_type, resource_id) do
    Repo.one(
      from i in StatusPageItem,
        where:
          i.status_page_id == ^status_page.id and
            i.resource_type == ^resource_type and
            i.resource_id == ^resource_id
    )
  end

  @doc """
  Lists all visible (badge-enabled) resources for an organization.

  Queries status_page_items joined with resource tables. Returns a map
  with :tasks, :monitors, :endpoints, and :queues lists.
  """
  def list_visible_resources(%Organization{} = org) do
    case get_status_page(org) do
      nil ->
        %{tasks: [], monitors: [], endpoints: [], queues: []}

      status_page ->
        items = list_items(status_page)

        task_ids = for %{resource_type: "task", resource_id: id} <- items, do: id
        monitor_ids = for %{resource_type: "monitor", resource_id: id} <- items, do: id
        endpoint_ids = for %{resource_type: "endpoint", resource_id: id} <- items, do: id
        queue_ids = for %{resource_type: "queue", resource_id: id} <- items, do: id

        tasks =
          if task_ids != [] do
            from(t in Prikke.Tasks.Task,
              where: t.id in ^task_ids and t.schedule_type == "cron" and is_nil(t.deleted_at),
              order_by: [asc: t.name]
            )
            |> Repo.all()
          else
            []
          end

        monitors =
          if monitor_ids != [] do
            from(m in Prikke.Monitors.Monitor,
              where: m.id in ^monitor_ids,
              order_by: [asc: m.name]
            )
            |> Repo.all()
          else
            []
          end

        endpoints =
          if endpoint_ids != [] do
            from(e in Prikke.Endpoints.Endpoint,
              where: e.id in ^endpoint_ids,
              order_by: [asc: e.name]
            )
            |> Repo.all()
          else
            []
          end

        queues =
          if queue_ids != [] do
            from(q in Prikke.Queues.Queue,
              where: q.id in ^queue_ids,
              order_by: [asc: q.name]
            )
            |> Repo.all()
          else
            []
          end

        %{tasks: tasks, monitors: monitors, endpoints: endpoints, queues: queues}
    end
  end

  @doc """
  Generates a URL-safe slug from a string.
  """
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> case do
      slug when byte_size(slug) < 3 -> slug <> "-status"
      slug -> String.slice(slug, 0, 60)
    end
  end
end
