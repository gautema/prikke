defmodule PrikkeWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for the Runlater API.
  """
  alias OpenApiSpex.{Info, OpenApi, Paths, Server, Components, SecurityScheme}
  alias PrikkeWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [
        Server.from_endpoint(Endpoint)
      ],
      info: %Info{
        title: "Runlater API",
        version: "1.0.0",
        description: """
        API for managing scheduled jobs and webhooks.

        ## Authentication

        All API requests require a Bearer token in the Authorization header:

        ```
        Authorization: Bearer pk_live_xxx.sk_live_yyy
        ```

        API keys can be created in the Runlater dashboard under Organization Settings.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "API key in format: pk_live_xxx.sk_live_yyy"
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
