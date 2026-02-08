defmodule PrikkeWeb.CacheBodyReader do
  @moduledoc """
  A body reader that caches the raw body in the connection's private assigns.

  Used for inbound webhook endpoints that need access to the raw request body
  after Plug.Parsers has consumed it.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = update_in(conn.private[:raw_body], &[body | &1 || []])
        {:ok, body, conn}

      {:more, body, conn} ->
        conn = update_in(conn.private[:raw_body], &[body | &1 || []])
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_raw_body(conn) do
    case conn.private[:raw_body] do
      nil -> ""
      parts -> parts |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
