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

  def format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  def format_number(n), do: "#{n}"

  def usage_percent(_current, 0), do: 0
  def usage_percent(current, limit), do: round(current / limit * 100)

  def usage_bar_color(current, limit) do
    percent = usage_percent(current, limit)

    cond do
      percent >= 100 -> "bg-red-500"
      percent >= 80 -> "bg-amber-500"
      true -> "bg-emerald-500"
    end
  end
end
