defmodule PrikkeWeb.Api.OpenApiController do
  use PrikkeWeb, :controller

  @doc """
  Serves the OpenAPI specification as JSON.
  """
  def spec(conn, _params) do
    json(conn, PrikkeWeb.ApiSpec.spec())
  end
end
