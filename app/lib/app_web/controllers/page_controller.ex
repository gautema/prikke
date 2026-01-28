defmodule PrikkeWeb.PageController do
  use PrikkeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
