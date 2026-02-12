defmodule Prikke.StatusPages do
  @moduledoc """
  The StatusPages context for customer-facing public status pages.

  Each organization can have one status page that displays the status
  of their badge-enabled tasks, monitors, and endpoints.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.StatusPages.StatusPage
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

  @doc """
  Lists all visible (badge-enabled) resources for an organization.

  Returns a map with :tasks, :monitors, and :endpoints lists.
  """
  def list_visible_resources(%Organization{} = org) do
    %{
      tasks: Prikke.Tasks.list_badge_enabled_tasks(org),
      monitors: Prikke.Monitors.list_badge_enabled_monitors(org),
      endpoints: Prikke.Endpoints.list_badge_enabled_endpoints(org)
    }
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
