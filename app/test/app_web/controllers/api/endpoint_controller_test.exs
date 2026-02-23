defmodule PrikkeWeb.Api.EndpointControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.EndpointsFixtures

  alias Prikke.Accounts
  alias Prikke.Endpoints

  setup %{conn: conn} do
    org = organization_fixture()
    user = user_fixture()
    {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user, %{name: "Test Key"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key_id}.#{raw_secret}")

    %{conn: conn, org: org}
  end

  describe "GET /api/v1/endpoints" do
    test "lists all endpoints for the organization", %{conn: conn, org: org} do
      _e1 = endpoint_fixture(org, %{name: "Endpoint 1"})
      _e2 = endpoint_fixture(org, %{name: "Endpoint 2"})

      conn = get(conn, ~p"/api/v1/endpoints")
      response = json_response(conn, 200)

      assert length(response["data"]) == 2
      names = Enum.map(response["data"], & &1["name"])
      assert "Endpoint 1" in names
      assert "Endpoint 2" in names
    end

    test "returns empty list when no endpoints", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/endpoints")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns 401 without auth" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/endpoints")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "does not list endpoints from other orgs", %{conn: conn} do
      other_org = organization_fixture()
      _other_endpoint = endpoint_fixture(other_org, %{name: "Other Endpoint"})

      conn = get(conn, ~p"/api/v1/endpoints")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "GET /api/v1/endpoints/:id" do
    test "returns the endpoint with inbound_url and forward_urls", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org, %{name: "Test Endpoint"})

      conn = get(conn, ~p"/api/v1/endpoints/#{endpoint.id}")
      response = json_response(conn, 200)

      assert response["data"]["id"] == endpoint.id
      assert response["data"]["name"] == "Test Endpoint"
      assert response["data"]["slug"] == endpoint.slug
      assert response["data"]["inbound_url"] =~ "/in/#{endpoint.slug}"
      assert response["data"]["forward_urls"] == ["https://example.com/webhooks/test"]
    end

    test "returns 404 for non-existent endpoint", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/endpoints/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/endpoints" do
    test "creates an endpoint with forward_urls array", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/endpoints", %{
          name: "Stripe",
          forward_urls: ["https://myapp.com/webhooks/stripe"]
        })

      response = json_response(conn, 201)
      assert response["data"]["name"] == "Stripe"
      assert response["data"]["forward_urls"] == ["https://myapp.com/webhooks/stripe"]
      assert response["data"]["slug"] =~ "ep_"
      assert response["data"]["inbound_url"] =~ "/in/ep_"
    end

    test "creates endpoint with forward_url string (backward compat)", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/endpoints", %{
          name: "Legacy",
          forward_url: "https://myapp.com/webhooks/legacy"
        })

      response = json_response(conn, 201)
      assert response["data"]["forward_urls"] == ["https://myapp.com/webhooks/legacy"]
    end

    test "creates endpoint with multiple forward_urls", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/endpoints", %{
          name: "Fan-out",
          forward_urls: [
            "https://old-system.com/hook",
            "https://new-system.com/hook"
          ]
        })

      response = json_response(conn, 201)

      assert response["data"]["forward_urls"] == [
               "https://old-system.com/hook",
               "https://new-system.com/hook"
             ]
    end

    test "creates endpoint with custom retry_attempts and use_queue", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/endpoints", %{
          name: "Custom Config",
          forward_urls: ["https://myapp.com/webhooks/stripe"],
          retry_attempts: 3,
          use_queue: false
        })

      response = json_response(conn, 201)
      assert response["data"]["retry_attempts"] == 3
      assert response["data"]["use_queue"] == false
    end

    test "creates endpoint with default retry_attempts and use_queue", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/endpoints", %{
          name: "Defaults",
          forward_urls: ["https://myapp.com/webhooks/stripe"]
        })

      response = json_response(conn, 201)
      assert response["data"]["retry_attempts"] == 5
      assert response["data"]["use_queue"] == true
    end

    test "returns validation error for missing fields", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/endpoints", %{})
      assert json_response(conn, 422)
    end
  end

  describe "PUT /api/v1/endpoints/:id" do
    test "updates an endpoint", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      conn =
        put(conn, ~p"/api/v1/endpoints/#{endpoint.id}", %{
          name: "Updated Name"
        })

      response = json_response(conn, 200)
      assert response["data"]["name"] == "Updated Name"
    end

    test "updates retry_attempts and use_queue", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      conn =
        put(conn, ~p"/api/v1/endpoints/#{endpoint.id}", %{
          retry_attempts: 0,
          use_queue: false
        })

      response = json_response(conn, 200)
      assert response["data"]["retry_attempts"] == 0
      assert response["data"]["use_queue"] == false
    end

    test "returns 404 for non-existent endpoint", %{conn: conn} do
      conn =
        put(conn, ~p"/api/v1/endpoints/#{Ecto.UUID.generate()}", %{
          name: "Updated"
        })

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/endpoints/:id" do
    test "deletes an endpoint", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      conn = delete(conn, ~p"/api/v1/endpoints/#{endpoint.id}")
      assert response(conn, 204)

      assert Endpoints.get_endpoint(org, endpoint.id) == nil
    end
  end

  describe "GET /api/v1/endpoints/:endpoint_id/events" do
    test "lists events with task_ids and status", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      {:ok, _} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      conn = get(conn, ~p"/api/v1/endpoints/#{endpoint.id}/events")
      response = json_response(conn, 200)

      assert length(response["data"]) == 1
      event = hd(response["data"])
      assert event["method"] == "POST"
      assert event["source_ip"] == "1.2.3.4"
      assert is_list(event["task_ids"])
      assert length(event["task_ids"]) == 1
    end
  end

  describe "POST /api/v1/endpoints/:endpoint_id/events/:event_id/replay" do
    test "replays an event and returns executions array", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      conn = post(conn, ~p"/api/v1/endpoints/#{endpoint.id}/events/#{event.id}/replay")
      response = json_response(conn, 202)

      assert is_list(response["data"]["executions"])
      assert length(response["data"]["executions"]) == 1
      assert hd(response["data"]["executions"])["status"] == "pending"
      assert response["message"] =~ "Event replayed"
    end
  end
end
