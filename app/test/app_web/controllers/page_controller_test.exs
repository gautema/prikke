defmodule PrikkeWeb.PageControllerTest do
  use PrikkeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Webhooks, cron, and queues"
  end
end
