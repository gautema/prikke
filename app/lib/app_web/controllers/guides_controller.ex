defmodule PrikkeWeb.GuidesController do
  use PrikkeWeb, :controller

  plug :put_layout, false
  plug :assign_hide_header

  defp assign_hide_header(conn, _opts) do
    conn
    |> assign(:hide_header, true)
    |> assign(:hide_footer, true)
  end

  def index(conn, _params) do
    render(conn, :index, page_title: "Framework Guides")
  end

  def nextjs(conn, _params) do
    render(conn, :nextjs, page_title: "Background Jobs in Next.js")
  end

  def cloudflare_workers(conn, _params) do
    render(conn, :cloudflare_workers, page_title: "Cron Jobs in Cloudflare Workers")
  end

  def supabase(conn, _params) do
    render(conn, :supabase, page_title: "Scheduled Tasks with Supabase")
  end

  def webhook_proxy(conn, _params) do
    render(conn, :webhook_proxy, page_title: "Never Lose a Webhook Again")
  end
end
