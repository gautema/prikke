defmodule Prikke.StatusPagesTest do
  use Prikke.DataCase

  alias Prikke.StatusPages
  alias Prikke.StatusPages.StatusPage

  import Prikke.AccountsFixtures
  import Prikke.TasksFixtures
  import Prikke.MonitorsFixtures
  import Prikke.EndpointsFixtures
  import Prikke.StatusPagesFixtures

  describe "get_or_create_status_page/1" do
    test "creates a status page with defaults when none exists" do
      org = organization_fixture()

      assert {:ok, %StatusPage{} = sp} = StatusPages.get_or_create_status_page(org)
      assert sp.title == org.name
      assert sp.enabled == false
      assert sp.organization_id == org.id
      assert sp.slug != nil
    end

    test "returns existing status page when one exists" do
      org = organization_fixture()
      existing = status_page_fixture(org, %{title: "Custom Title"})

      assert {:ok, %StatusPage{} = sp} = StatusPages.get_or_create_status_page(org)
      assert sp.id == existing.id
      assert sp.title == "Custom Title"
    end
  end

  describe "update_status_page/2" do
    test "updates title and slug" do
      org = organization_fixture()
      sp = status_page_fixture(org)

      assert {:ok, updated} =
               StatusPages.update_status_page(sp, %{title: "New Title", slug: "new-slug"})

      assert updated.title == "New Title"
      assert updated.slug == "new-slug"
    end

    test "enables the page" do
      org = organization_fixture()
      sp = status_page_fixture(org, %{enabled: false})

      assert {:ok, updated} = StatusPages.update_status_page(sp, %{enabled: true})
      assert updated.enabled == true
    end

    test "validates slug format" do
      org = organization_fixture()
      sp = status_page_fixture(org)

      assert {:error, changeset} = StatusPages.update_status_page(sp, %{slug: "AB"})
      assert errors_on(changeset).slug != []
    end

    test "validates reserved slugs" do
      org = organization_fixture()
      sp = status_page_fixture(org)

      assert {:error, changeset} = StatusPages.update_status_page(sp, %{slug: "admin"})
      assert "is reserved" in errors_on(changeset).slug
    end

    test "validates slug uniqueness" do
      org1 = organization_fixture()
      org2 = organization_fixture()
      _sp1 = status_page_fixture(org1, %{slug: "taken-slug"})
      sp2 = status_page_fixture(org2, %{slug: "other-slug"})

      assert {:error, changeset} = StatusPages.update_status_page(sp2, %{slug: "taken-slug"})
      assert errors_on(changeset).slug != []
    end
  end

  describe "get_public_status_page/1" do
    test "returns enabled status page by slug" do
      org = organization_fixture()
      sp = status_page_fixture(org, %{enabled: true, slug: "my-page"})

      result = StatusPages.get_public_status_page("my-page")
      assert result.id == sp.id
      assert result.organization != nil
    end

    test "returns nil for disabled status page" do
      org = organization_fixture()
      _sp = status_page_fixture(org, %{enabled: false, slug: "disabled-page"})

      assert StatusPages.get_public_status_page("disabled-page") == nil
    end

    test "returns nil for non-existent slug" do
      assert StatusPages.get_public_status_page("does-not-exist") == nil
    end
  end

  describe "status page items" do
    test "add_item/3 creates an item with badge token" do
      org = organization_fixture()
      sp = status_page_fixture(org)
      task = task_fixture(org, %{name: "My Task"})

      assert {:ok, item} = StatusPages.add_item(sp, "task", task.id)
      assert item.resource_type == "task"
      assert item.resource_id == task.id
      assert item.status_page_id == sp.id
      assert String.starts_with?(item.badge_token, "bt_")
    end

    test "add_item/3 prevents duplicate items" do
      org = organization_fixture()
      sp = status_page_fixture(org)
      task = task_fixture(org)

      {:ok, _} = StatusPages.add_item(sp, "task", task.id)
      assert {:error, _changeset} = StatusPages.add_item(sp, "task", task.id)
    end

    test "remove_item/3 removes an existing item" do
      org = organization_fixture()
      sp = status_page_fixture(org)
      task = task_fixture(org)

      {:ok, _item} = StatusPages.add_item(sp, "task", task.id)
      assert {:ok, _} = StatusPages.remove_item(sp, "task", task.id)
      assert StatusPages.get_item(sp, "task", task.id) == nil
    end

    test "remove_item/3 returns error for missing item" do
      org = organization_fixture()
      sp = status_page_fixture(org)

      assert {:error, :not_found} = StatusPages.remove_item(sp, "task", Ecto.UUID.generate())
    end

    test "get_item_by_badge_token/1 finds item by token" do
      org = organization_fixture()
      sp = status_page_fixture(org)
      task = task_fixture(org)

      {:ok, item} = StatusPages.add_item(sp, "task", task.id)

      found = StatusPages.get_item_by_badge_token(item.badge_token)
      assert found.id == item.id
    end

    test "get_item_by_badge_token/1 returns nil for missing token" do
      assert StatusPages.get_item_by_badge_token("bt_nonexistent000000000000") == nil
    end

    test "get_item_by_badge_token/1 returns nil for nil" do
      assert StatusPages.get_item_by_badge_token(nil) == nil
    end

    test "list_items/1 returns all items for a status page" do
      org = organization_fixture()
      sp = status_page_fixture(org)
      task = task_fixture(org)
      monitor = monitor_fixture(org)

      {:ok, _} = StatusPages.add_item(sp, "task", task.id)
      {:ok, _} = StatusPages.add_item(sp, "monitor", monitor.id)

      items = StatusPages.list_items(sp)
      assert length(items) == 2
    end
  end

  describe "list_visible_resources/1" do
    test "returns only resources with status page items" do
      org = organization_fixture()
      sp = status_page_fixture(org)

      # Create tasks - one with item, one without
      task1 = task_fixture(org, %{name: "With Badge"})
      _task2 = task_fixture(org, %{name: "Without Badge"})
      StatusPages.add_item(sp, "task", task1.id)

      # Create monitors - one with item, one without
      monitor1 = monitor_fixture(org, %{name: "With Badge Mon"})
      _monitor2 = monitor_fixture(org, %{name: "Without Badge Mon"})
      StatusPages.add_item(sp, "monitor", monitor1.id)

      # Create endpoints - one with item, one without
      endpoint1 = endpoint_fixture(org, %{name: "With Badge EP"})
      _endpoint2 = endpoint_fixture(org, %{name: "Without Badge EP"})
      StatusPages.add_item(sp, "endpoint", endpoint1.id)

      resources = StatusPages.list_visible_resources(org)

      assert length(resources.tasks) == 1
      assert hd(resources.tasks).name == "With Badge"
      assert length(resources.monitors) == 1
      assert hd(resources.monitors).name == "With Badge Mon"
      assert length(resources.endpoints) == 1
      assert hd(resources.endpoints).name == "With Badge EP"
    end

    test "returns empty lists when no items" do
      org = organization_fixture()
      resources = StatusPages.list_visible_resources(org)

      assert resources.tasks == []
      assert resources.monitors == []
      assert resources.endpoints == []
      assert resources.queues == []
    end

    test "includes queues" do
      org = organization_fixture()
      sp = status_page_fixture(org)
      queue = Prikke.Queues.get_or_create_queue!(org, "emails")
      StatusPages.add_item(sp, "queue", queue.id)

      resources = StatusPages.list_visible_resources(org)
      assert length(resources.queues) == 1
      assert hd(resources.queues).name == "emails"
    end
  end

  describe "slugify/1" do
    test "converts name to slug" do
      assert StatusPages.slugify("My Company") == "my-company"
    end

    test "handles special characters" do
      assert StatusPages.slugify("Acme Corp!") == "acme-corp"
    end

    test "ensures minimum length" do
      assert StatusPages.slugify("AB") == "ab-status"
    end

    test "truncates long names" do
      long_name = String.duplicate("a", 100)
      slug = StatusPages.slugify(long_name)
      assert String.length(slug) <= 60
    end
  end

  describe "change_status_page/2" do
    test "returns a changeset" do
      org = organization_fixture()
      sp = status_page_fixture(org)

      changeset = StatusPages.change_status_page(sp, %{title: "New"})
      assert %Ecto.Changeset{} = changeset
    end
  end
end
