defmodule PrikkeWeb.NotFoundError do
  defexception message: "not found", plug_status: 404
end

defimpl Plug.Exception, for: PrikkeWeb.NotFoundError do
  def status(_), do: 404
  def actions(_), do: []
end
