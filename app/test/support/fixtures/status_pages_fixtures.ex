defmodule Prikke.StatusPagesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Prikke.StatusPages` context.
  """

  import Prikke.AccountsFixtures, only: [organization_fixture: 0]

  def status_page_fixture(org \\ nil, attrs \\ %{})

  def status_page_fixture(nil, attrs) do
    status_page_fixture(organization_fixture(), attrs)
  end

  def status_page_fixture(org, attrs) do
    attrs =
      Enum.into(attrs, %{
        title: org.name,
        slug: "test-status-#{System.unique_integer([:positive])}",
        enabled: true
      })

    {:ok, status_page} =
      %Prikke.StatusPages.StatusPage{}
      |> Prikke.StatusPages.StatusPage.create_changeset(attrs, org.id)
      |> Prikke.Repo.insert()

    status_page
  end

  @doc """
  Adds a resource to a status page, creating a status_page_item with a badge_token.
  Returns the created item.
  """
  def add_status_page_item(status_page, resource_type, resource_id) do
    {:ok, item} = Prikke.StatusPages.add_item(status_page, resource_type, resource_id)
    item
  end
end
