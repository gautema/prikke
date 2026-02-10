defmodule PrikkeWeb.Api.ApiController do
  @moduledoc """
  Shared behaviour for API controllers.

  Use this module instead of `use PrikkeWeb, :controller` in API controllers
  to get automatic handling of DB pool exhaustion (503 instead of 500).
  """

  defmacro __using__(_opts) do
    quote do
      use PrikkeWeb, :controller

      @doc false
      def action(conn, _opts) do
        apply(__MODULE__, action_name(conn), [conn, conn.params])
      rescue
        _e in DBConnection.ConnectionError ->
          conn
          |> put_status(:service_unavailable)
          |> put_resp_header("retry-after", "5")
          |> json(%{
            error: %{code: "service_unavailable", message: "Server is busy, please retry"}
          })
      end

      defoverridable action: 2
    end
  end
end
