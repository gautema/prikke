defmodule PrikkeWeb.InboundController do
  use PrikkeWeb, :controller

  alias Prikke.Endpoints

  def receive(conn, %{"slug" => slug}) do
    case Endpoints.get_endpoint_by_slug(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})

      %{enabled: false} ->
        conn
        |> put_status(:gone)
        |> json(%{error: "Endpoint disabled"})

      endpoint ->
        body = PrikkeWeb.CacheBodyReader.get_raw_body(conn)
        headers = Map.new(conn.req_headers)
        source_ip = original_ip(conn)

        case Endpoints.receive_event(endpoint, %{
               method: conn.method,
               headers: headers,
               body: body,
               source_ip: source_ip
             }) do
          {:ok, event} ->
            conn
            |> put_status(:ok)
            |> json(%{id: event.id, status: "received"})

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to process event"})
        end
    end
  end

  defp original_ip(conn) do
    forwarded_for =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> List.first()

    if forwarded_for do
      forwarded_for |> String.split(",") |> List.first() |> String.trim()
    else
      conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
