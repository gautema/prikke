defmodule PrikkeWeb.Plugs.ApiAuthTest do
  use PrikkeWeb.ConnCase

  alias PrikkeWeb.Plugs.ApiAuth
  alias Prikke.Accounts

  import Prikke.AccountsFixtures

  describe "ApiAuth plug" do
    setup do
      user = user_fixture()
      {:ok, org} = Accounts.create_organization(user, %{name: "Test", slug: "test"})
      {:ok, api_key, raw_secret} = Accounts.create_api_key(org, user)
      full_key = "#{api_key.key_id}.#{raw_secret}"

      %{org: org, full_key: full_key}
    end

    test "assigns organization with valid API key", %{conn: conn, org: org, full_key: full_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{full_key}")
        |> ApiAuth.call([])

      assert conn.assigns[:current_organization].id == org.id
      refute conn.halted
    end

    test "returns 401 with missing authorization header", %{conn: conn} do
      conn = ApiAuth.call(conn, [])

      assert conn.status == 401
      assert conn.halted

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{"code" => "unauthorized", "message" => "Invalid or missing API key"}
             }
    end

    test "returns 401 with invalid API key format", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid")
        |> ApiAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 with invalid secret", %{conn: conn, full_key: full_key} do
      [key_id, _] = String.split(full_key, ".")
      bad_key = "#{key_id}.sk_live_wrongsecret"

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{bad_key}")
        |> ApiAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 with non-existent key_id", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer pk_live_nonexistent.sk_live_secret")
        |> ApiAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end
end
