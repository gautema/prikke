defmodule PrikkeWeb.Plugs.IdempotencyTest do
  use PrikkeWeb.ConnCase, async: true

  import Prikke.AccountsFixtures

  alias Prikke.Idempotency

  setup %{conn: conn} do
    org = organization_fixture()

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:current_organization, org)

    %{conn: conn, org: org}
  end

  describe "call/2" do
    test "passes through when no Idempotency-Key header", %{conn: conn} do
      conn = PrikkeWeb.Plugs.Idempotency.call(conn, [])
      refute conn.halted
      refute conn.assigns[:idempotency_key]
    end

    test "passes through with empty Idempotency-Key header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("idempotency-key", "")
        |> PrikkeWeb.Plugs.Idempotency.call([])

      refute conn.halted
      refute conn.assigns[:idempotency_key]
    end

    test "assigns key and registers before_send when key is new", %{conn: conn} do
      conn =
        conn
        |> put_req_header("idempotency-key", "new-key-123")
        |> PrikkeWeb.Plugs.Idempotency.call([])

      refute conn.halted
      assert conn.assigns[:idempotency_key] == "new-key-123"
    end

    test "returns cached response when key exists", %{conn: conn, org: org} do
      # Pre-store a response
      {:ok, _} =
        Idempotency.store_response(org.id, "existing-key", 202, ~s({"data":{"job_id":"abc"}}))

      conn =
        conn
        |> put_req_header("idempotency-key", "existing-key")
        |> PrikkeWeb.Plugs.Idempotency.call([])

      assert conn.halted
      assert conn.status == 202
      assert conn.resp_body == ~s({"data":{"job_id":"abc"}})
    end

    test "passes through when no organization assigned", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.assign(:current_organization, nil)
        |> put_req_header("idempotency-key", "some-key")
        |> PrikkeWeb.Plugs.Idempotency.call([])

      refute conn.halted
    end
  end
end
