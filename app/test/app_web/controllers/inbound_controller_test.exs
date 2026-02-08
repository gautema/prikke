defmodule PrikkeWeb.InboundControllerTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures
  import Prikke.EndpointsFixtures

  describe "POST /in/:slug" do
    test "returns 200 with event ID for valid slug", %{conn: conn} do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/in/#{endpoint.slug}", ~s({"event": "test"}))

      response = json_response(conn, 200)
      assert response["id"]
      assert response["status"] == "received"
    end

    test "returns 404 for invalid slug", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/in/ep_nonexistent", ~s({"test": true}))

      assert json_response(conn, 404)["error"] == "Not found"
    end

    test "returns 410 for disabled endpoint", %{conn: conn} do
      org = organization_fixture()
      endpoint = endpoint_fixture(org, %{enabled: false})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/in/#{endpoint.slug}", ~s({"test": true}))

      assert json_response(conn, 410)["error"] == "Endpoint disabled"
    end

    test "stores headers and body correctly", %{conn: conn} do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-custom-header", "custom-value")
        |> post("/in/#{endpoint.slug}", ~s({"payload": "data"}))

      assert json_response(conn, 200)["status"] == "received"

      events = Prikke.Endpoints.list_inbound_events(endpoint)
      assert length(events) == 1
      event = hd(events)
      assert event.method == "POST"
      assert event.body == ~s({"payload": "data"})
    end

    test "accepts PUT requests", %{conn: conn} do
      org = organization_fixture()
      endpoint = endpoint_fixture(org)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/in/#{endpoint.slug}", ~s({"test": true}))

      assert json_response(conn, 200)["status"] == "received"
    end
  end
end
