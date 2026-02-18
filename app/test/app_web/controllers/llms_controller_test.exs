defmodule PrikkeWeb.LlmsControllerTest do
  use PrikkeWeb.ConnCase, async: true

  describe "GET /llms.txt" do
    test "returns plain text with llms.txt content", %{conn: conn} do
      conn = get(conn, "/llms.txt")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

      body = response(conn, 200)
      assert body =~ "# Runlater"
      assert body =~ "Authorization: Bearer"
      assert body =~ "/api/v1/tasks"
      assert body =~ "/api/v1/monitors"
      assert body =~ "/api/v1/endpoints"
      assert body =~ "## Documentation"
    end
  end
end
