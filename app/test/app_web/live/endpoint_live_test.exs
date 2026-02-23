defmodule PrikkeWeb.EndpointLiveTest do
  use PrikkeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prikke.AccountsFixtures
  import Prikke.EndpointsFixtures

  alias Prikke.Endpoints

  setup %{conn: conn} do
    user = user_fixture()
    org = organization_fixture(%{user: user})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, org.id)

    %{conn: conn, user: user, org: org}
  end

  describe "Index" do
    test "shows empty state when no endpoints", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/endpoints")

      assert has_element?(view, "h3", "No endpoints yet")
    end

    test "lists endpoints", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org, %{name: "Stripe Hooks"})

      {:ok, view, _html} = live(conn, ~p"/endpoints")

      assert has_element?(view, "a", "Stripe Hooks")
      assert render(view) =~ endpoint.slug
    end

    test "can delete an endpoint", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org, %{name: "To Delete"})

      {:ok, view, _html} = live(conn, ~p"/endpoints")
      assert has_element?(view, "a", "To Delete")

      view
      |> element(~s{button[phx-click="delete"][phx-value-id="#{endpoint.id}"]})
      |> render_click()

      refute has_element?(view, "a", "To Delete")
    end
  end

  describe "New" do
    test "creates endpoint and redirects", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/endpoints/new")

      assert has_element?(view, "#endpoint-form")

      view
      |> form("#endpoint-form", %{
        "endpoint" => %{
          "name" => "GitHub webhooks",
          "forward_urls" => %{"0" => "https://myapp.com/webhooks/github"}
        }
      })
      |> render_submit()

      assert_redirect(view)
    end

    test "shows validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/endpoints/new")

      view
      |> form("#endpoint-form", endpoint: %{name: ""})
      |> render_change()

      assert has_element?(view, "#endpoint-form")
    end
  end

  describe "Show" do
    test "displays endpoint details with forward URLs", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org, %{name: "Stripe webhooks"})

      {:ok, view, _html} = live(conn, ~p"/endpoints/#{endpoint.id}")

      assert has_element?(view, "h1", "Stripe webhooks")
      assert render(view) =~ endpoint.slug
      assert render(view) =~ hd(endpoint.forward_urls)
    end

    test "shows no events message", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/endpoints/#{endpoint.id}")

      assert has_element?(view, "p", "No events received yet")
    end

    test "shows events after receiving", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      {:ok, _event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      {:ok, view, _html} = live(conn, ~p"/endpoints/#{endpoint.id}")

      assert render(view) =~ "POST"
      assert has_element?(view, ~s{a[href*="/events/"]})
    end
  end

  describe "Edit" do
    test "updates endpoint", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org, %{name: "Old Name"})

      {:ok, view, _html} = live(conn, ~p"/endpoints/#{endpoint.id}/edit")

      view
      |> form("#endpoint-form", endpoint: %{name: "New Name"})
      |> render_submit()

      assert_redirect(view)

      updated = Endpoints.get_endpoint!(org, endpoint.id)
      assert updated.name == "New Name"
    end
  end
end
