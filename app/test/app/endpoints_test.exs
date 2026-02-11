defmodule Prikke.EndpointsTest do
  use Prikke.DataCase, async: true

  alias Prikke.Endpoints

  import Prikke.AccountsFixtures
  import Prikke.EndpointsFixtures

  describe "CRUD" do
    test "create_endpoint/2 creates an endpoint with a slug" do
      org = organization_fixture()

      {:ok, endpoint} =
        Endpoints.create_endpoint(org, %{
          name: "Stripe webhooks",
          forward_url: "https://myapp.com/webhooks/stripe"
        })

      assert endpoint.name == "Stripe webhooks"
      assert endpoint.forward_url == "https://myapp.com/webhooks/stripe"
      assert endpoint.enabled == true
      assert String.starts_with?(endpoint.slug, "ep_")
      assert String.length(endpoint.slug) == 35
      assert endpoint.organization_id == org.id
    end

    test "create_endpoint/2 validates required fields" do
      org = organization_fixture()

      assert {:error, changeset} = Endpoints.create_endpoint(org, %{})
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).forward_url
    end

    test "create_endpoint/2 validates forward_url is HTTP(S)" do
      org = organization_fixture()

      assert {:error, changeset} =
               Endpoints.create_endpoint(org, %{
                 name: "Bad URL",
                 forward_url: "ftp://invalid.com"
               })

      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).forward_url
    end

    test "create_endpoint/2 enforces tier limits" do
      org = organization_fixture(%{tier: "free"})

      # Create max endpoints for free tier
      for _ <- 1..3 do
        endpoint_fixture(org)
      end

      assert {:error, changeset} =
               Endpoints.create_endpoint(org, %{
                 name: "One too many",
                 forward_url: "https://example.com/hook"
               })

      assert errors_on(changeset).base != []
    end

    test "create_endpoint/2 allows unlimited for pro tier" do
      org = organization_fixture(%{tier: "pro"})

      for _ <- 1..5 do
        endpoint_fixture(org)
      end

      assert {:ok, _} =
               Endpoints.create_endpoint(org, %{
                 name: "Another one",
                 forward_url: "https://example.com/hook"
               })
    end

    test "update_endpoint/4 updates fields" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      {:ok, updated} =
        Endpoints.update_endpoint(org, endpoint, %{
          name: "Updated Name",
          forward_url: "https://new-url.com/hook"
        })

      assert updated.name == "Updated Name"
      assert updated.forward_url == "https://new-url.com/hook"
    end

    test "delete_endpoint/3 deletes endpoint" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      assert {:ok, _} = Endpoints.delete_endpoint(org, endpoint)
      assert Endpoints.get_endpoint(org, endpoint.id) == nil
    end

    test "list_endpoints/1 lists org endpoints" do
      org = organization_fixture()
      e1 = endpoint_fixture(org, %{name: "Endpoint 1"})
      e2 = endpoint_fixture(org, %{name: "Endpoint 2"})

      other_org = organization_fixture()
      _other = endpoint_fixture(other_org, %{name: "Other"})

      endpoints = Endpoints.list_endpoints(org)
      ids = Enum.map(endpoints, & &1.id)
      assert e1.id in ids
      assert e2.id in ids
      assert length(endpoints) == 2
    end

    test "get_endpoint!/2 returns endpoint" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      fetched = Endpoints.get_endpoint!(org, endpoint.id)
      assert fetched.id == endpoint.id
    end

    test "get_endpoint_by_slug/1 returns endpoint with org" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      fetched = Endpoints.get_endpoint_by_slug(endpoint.slug)
      assert fetched.id == endpoint.id
      assert fetched.organization.id == org.id
    end

    test "get_endpoint_by_slug/1 returns nil for unknown slug" do
      assert Endpoints.get_endpoint_by_slug("ep_nonexistent") == nil
    end

    test "slug uniqueness" do
      org = organization_fixture()
      e1 = endpoint_fixture(org)
      e2 = endpoint_fixture(org)

      assert e1.slug != e2.slug
    end

    test "create_endpoint/2 sets default retry_attempts and use_queue" do
      org = organization_fixture()

      {:ok, endpoint} =
        Endpoints.create_endpoint(org, %{
          name: "Defaults",
          forward_url: "https://example.com/hook"
        })

      assert endpoint.retry_attempts == 5
      assert endpoint.use_queue == true
    end

    test "create_endpoint/2 accepts custom retry_attempts and use_queue" do
      org = organization_fixture()

      {:ok, endpoint} =
        Endpoints.create_endpoint(org, %{
          name: "Custom",
          forward_url: "https://example.com/hook",
          retry_attempts: 2,
          use_queue: false
        })

      assert endpoint.retry_attempts == 2
      assert endpoint.use_queue == false
    end

    test "create_endpoint/2 validates retry_attempts range" do
      org = organization_fixture()

      assert {:error, changeset} =
               Endpoints.create_endpoint(org, %{
                 name: "Bad retries",
                 forward_url: "https://example.com/hook",
                 retry_attempts: 11
               })

      assert "must be less than or equal to 10" in errors_on(changeset).retry_attempts

      assert {:error, changeset} =
               Endpoints.create_endpoint(org, %{
                 name: "Bad retries",
                 forward_url: "https://example.com/hook",
                 retry_attempts: -1
               })

      assert "must be greater than or equal to 0" in errors_on(changeset).retry_attempts
    end

    test "update_endpoint/4 updates retry_attempts and use_queue" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      {:ok, updated} =
        Endpoints.update_endpoint(org, endpoint, %{
          retry_attempts: 0,
          use_queue: false
        })

      assert updated.retry_attempts == 0
      assert updated.use_queue == false
    end
  end

  describe "receive_event/2" do
    test "creates inbound event, task, and execution" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{"content-type" => "application/json"},
          body: ~s({"test": true}),
          source_ip: "1.2.3.4"
        })

      assert event.method == "POST"
      assert event.body == ~s({"test": true})
      assert event.source_ip == "1.2.3.4"
      assert event.endpoint_id == endpoint.id
      assert event.execution_id != nil
    end

    test "creates task with slugified endpoint name as queue" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org, %{name: "Stripe Webhooks"})

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      execution = Prikke.Repo.preload(event, execution: :task).execution
      assert execution.task.queue == "stripe-webhooks"
      assert execution.task.url == endpoint.forward_url
      assert execution.task.method == "POST"
    end

    test "uses endpoint retry_attempts on created task" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org, %{retry_attempts: 2})

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      execution = Prikke.Repo.preload(event, execution: :task).execution
      assert execution.task.retry_attempts == 2
    end

    test "sets queue to nil when use_queue is false" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org, %{name: "Parallel Hook", use_queue: false})

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      execution = Prikke.Repo.preload(event, execution: :task).execution
      assert execution.task.queue == nil
    end

    test "sets queue name when use_queue is true" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org, %{name: "Serial Hook", use_queue: true})

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      execution = Prikke.Repo.preload(event, execution: :task).execution
      assert execution.task.queue == "serial-hook"
    end
  end

  describe "replay_event/2" do
    test "creates new execution for existing event" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      event = Prikke.Repo.preload(event, :execution)
      {:ok, new_execution} = Endpoints.replay_event(endpoint, event)

      assert new_execution.id != event.execution_id
      assert new_execution.status == "pending"
    end
  end

  describe "inbound events" do
    test "list_inbound_events/2 returns events" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      {:ok, _} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "event 1",
          source_ip: "1.2.3.4"
        })

      {:ok, _} =
        Endpoints.receive_event(endpoint, %{
          method: "PUT",
          headers: %{},
          body: "event 2",
          source_ip: "5.6.7.8"
        })

      events = Endpoints.list_inbound_events(endpoint)
      assert length(events) == 2
    end

    test "count_inbound_events/1 returns count" do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      assert Endpoints.count_inbound_events(endpoint) == 0

      {:ok, _} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      assert Endpoints.count_inbound_events(endpoint) == 1
    end
  end
end
