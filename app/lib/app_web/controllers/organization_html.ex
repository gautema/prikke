defmodule PrikkeWeb.OrganizationHTML do
  use PrikkeWeb, :html

  embed_templates "organization_html/*"

  def role_badge_class("owner"), do: "bg-purple-100 text-purple-700"
  def role_badge_class("admin"), do: "bg-blue-100 text-blue-700"
  def role_badge_class(_), do: "bg-slate-100 text-slate-700"
end
