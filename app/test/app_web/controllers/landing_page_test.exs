defmodule PrikkeWeb.LandingPageTest do
  use PrikkeWeb.ConnCase, async: true

  describe "Landing page" do
    test "renders landing page for unauthenticated users", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # Check hero section
      assert html =~ "Async tasks without"
      assert html =~ "the infrastructure"
      assert html =~ "hosted in Europe"
      assert html =~ "forward webhooks"

      # Check marketing header is present
      assert html =~ "runlater"

      # Check CTA buttons
      assert html =~ "Start free"
      assert html =~ "View docs"

      # Check problem section
      assert html =~ "The problem"

      # Check core capabilities section
      assert html =~ "One API for all async work"
      assert html =~ "Queues"
      assert html =~ "Delays"
      assert html =~ "Crons"
      assert html =~ "Retries"
      assert html =~ "Callbacks"
      assert html =~ "Monitoring"

      # Check built for production section
      assert html =~ "Built for production"
      assert html =~ "Webhook signatures"
      assert html =~ "Idempotency"
      assert html =~ "Custom headers and payloads"
      assert html =~ "Full execution history"
      assert html =~ "Slack, Discord, or email"

      # Check why Runlater section
      assert html =~ "Why Runlater"
      assert html =~ "European-owned. Zero US subprocessors."
      assert html =~ "Bootstrapped. No pivot risk."
      assert html =~ "Built on the BEAM"
      assert html =~ "API-first with a dashboard"

      # Check tech mentions
      assert html =~ "Elixir"
      assert html =~ "BEAM"

      # Check pricing section
      assert html =~ "Simple pricing"
      assert html =~ "Free"
      assert html =~ "Pro"
      assert html =~ "Enterprise"
      assert html =~ "€29"
    end

    test "shows preview of landing page when logged in with ?preview=true", %{conn: conn} do
      user = Prikke.AccountsFixtures.user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/?preview=true")
      html = html_response(conn, 200)

      # Should show landing page content, not redirect
      assert html =~ "Async tasks without"
      assert html =~ "runlater"
    end

    test "redirects logged in users to dashboard", %{conn: conn} do
      user = Prikke.AccountsFixtures.user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/")

      assert redirected_to(conn) == ~p"/dashboard"
    end
  end

  describe "Docs pages" do
    test "renders docs index", %{conn: conn} do
      conn = get(conn, ~p"/docs")
      html = html_response(conn, 200)

      assert html =~ "Documentation"
      assert html =~ "runlater"
    end

    test "renders API docs", %{conn: conn} do
      conn = get(conn, ~p"/docs/api")
      html = html_response(conn, 200)

      assert html =~ "API Reference"
      assert html =~ "Authentication"
    end

    test "docs pages have pulsing logo", %{conn: conn} do
      conn = get(conn, ~p"/docs")
      html = html_response(conn, 200)

      assert html =~ "animate-[ping_4s"
    end
  end

  describe "Footer" do
    test "footer links are correct", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # Check footer links point to correct URLs
      assert html =~ ~s(href="/docs")
      assert html =~ ~s(href="/docs/api")
      assert html =~ ~s(href="/status")
    end
  end
end
