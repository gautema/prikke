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

  describe "New - add/remove URL" do
    test "add_url adds a second URL input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/endpoints/new")

      # Initially one URL input
      html = render(view)
      assert count_url_inputs(html) == 1

      # Click Add URL
      view |> element(~s{button[phx-click="add_url"]}) |> render_click()

      html = render(view)
      assert count_url_inputs(html) == 2
    end

    test "add_url preserves existing form data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/endpoints/new")

      # Fill in name and URL first
      view
      |> form("#endpoint-form", %{
        "endpoint" => %{
          "name" => "My Endpoint",
          "forward_urls" => %{"0" => "https://example.com/hook"}
        }
      })
      |> render_change()

      # Click Add URL
      view |> element(~s{button[phx-click="add_url"]}) |> render_click()

      # Name should still be there
      html = render(view)
      assert html =~ "My Endpoint"
      assert count_url_inputs(html) == 2
    end

    test "remove_url removes a URL input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/endpoints/new")

      # Add a second URL
      view |> element(~s{button[phx-click="add_url"]}) |> render_click()
      assert count_url_inputs(render(view)) == 2

      # Remove one
      view |> element(~s{button[phx-click="remove_url"][phx-value-index="1"]}) |> render_click()
      assert count_url_inputs(render(view)) == 1
    end

    test "can create endpoint with multiple URLs", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/endpoints/new")

      # Add second URL input
      view |> element(~s{button[phx-click="add_url"]}) |> render_click()

      # Submit with two URLs
      view
      |> form("#endpoint-form", %{
        "endpoint" => %{
          "name" => "Fan-out endpoint",
          "forward_urls" => %{
            "0" => "https://old.com/hook",
            "1" => "https://new.com/hook"
          }
        }
      })
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      endpoint_id = path |> String.split("/") |> List.last()
      endpoint = Endpoints.get_endpoint!(org, endpoint_id)
      assert endpoint.forward_urls == ["https://old.com/hook", "https://new.com/hook"]
    end
  end

  describe "Edit - add/remove URL" do
    test "add_url preserves existing endpoint data", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org, %{name: "Edit Test"})

      {:ok, view, _html} = live(conn, ~p"/endpoints/#{endpoint.id}/edit")

      # Click Add URL
      view |> element(~s{button[phx-click="add_url"]}) |> render_click()

      html = render(view)
      assert count_url_inputs(html) == 2
      # Original URL should still be visible
      assert html =~ hd(endpoint.forward_urls)
    end
  end

  describe "Event Show - replay" do
    test "replay button replays event", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      {:ok, view, _html} =
        live(conn, ~p"/endpoints/#{endpoint.id}/events/#{event.id}")

      view
      |> element(~s{button[phx-click="replay"]})
      |> render_click()

      assert render(view) =~ "Event replayed"
    end
  end

  describe "Event Show" do
    test "displays event details with tasks", %{conn: conn, org: org} do
      endpoint = endpoint_fixture(org)

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{"content-type" => "application/json"},
          body: ~s({"test": true}),
          source_ip: "1.2.3.4"
        })

      {:ok, view, _html} = live(conn, ~p"/endpoints/#{endpoint.id}/events/#{event.id}")

      html = render(view)
      assert html =~ "POST"
      assert html =~ "1.2.3.4"
      assert html =~ hd(endpoint.forward_urls)
    end

    test "displays multiple destinations for fan-out", %{conn: conn, org: org} do
      endpoint =
        endpoint_fixture(org, %{
          forward_urls: ["https://a.com/hook", "https://b.com/hook"]
        })

      {:ok, event} =
        Endpoints.receive_event(endpoint, %{
          method: "POST",
          headers: %{},
          body: "test",
          source_ip: "1.2.3.4"
        })

      {:ok, view, _html} = live(conn, ~p"/endpoints/#{endpoint.id}/events/#{event.id}")

      html = render(view)
      assert html =~ "https://a.com/hook"
      assert html =~ "https://b.com/hook"
    end
  end

  defp count_url_inputs(html) do
    Regex.scan(~r/name="endpoint\[forward_urls\]\[\d+\]"/, html) |> length()
  end
end
