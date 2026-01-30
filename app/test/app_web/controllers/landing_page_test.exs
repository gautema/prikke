defmodule PrikkeWeb.LandingPageTest do
  use PrikkeWeb.ConnCase, async: true

  describe "Landing page" do
    test "renders landing page for unauthenticated users", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # Check hero section
      assert html =~ "Cron for the"
      assert html =~ "serverless era"
      assert html =~ "Fire and forget"

      # Check pulsing logo is present
      assert html =~ "animate-[ping_4s"
      assert html =~ "cronly"

      # Check CTA buttons
      assert html =~ "Start free"
      assert html =~ "View docs"

      # Check problem section
      assert html =~ "The problem"
      assert html =~ "serverless"

      # Check what Cronly does section
      assert html =~ "What Cronly does"
      assert html =~ "Cron jobs"
      assert html =~ "One-time tasks"
      assert html =~ "Automatic retries"
      assert html =~ "Webhook delivery"

      # Check fire and forget section
      assert html =~ "Fire and forget"
      assert html =~ "Set it and sleep"
      assert html =~ "Retries handled"
      assert html =~ "Alerts when it matters"
      assert html =~ "Full history"

      # Check why Cronly section
      assert html =~ "Why Cronly"
      assert html =~ "EU-hosted, GDPR-native"
      assert html =~ "Built for reliability"
      assert html =~ "Privacy by design"
      assert html =~ "API + Dashboard"

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
      assert html =~ "Cron for the"
      assert html =~ "cronly"
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
      assert html =~ "cronly"
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
