defmodule PrikkeWeb.OrganizationHTML do
  use PrikkeWeb, :html

  embed_templates "organization_html/*"

  def role_badge_class("owner"), do: "bg-purple-100 text-purple-700"
  def role_badge_class("admin"), do: "bg-blue-100 text-blue-700"
  def role_badge_class(_), do: "bg-slate-100 text-slate-700"

  @doc """
  Check if the current user can change the role of a member.
  """
  def can_change_role?(nil, _member), do: false

  def can_change_role?(current_membership, member) do
    if current_membership.id == member.id do
      false
    else
      case {current_membership.role, member.role} do
        {"owner", role} when role in ["admin", "member"] -> true
        {"admin", "member"} -> true
        _ -> false
      end
    end
  end
end
