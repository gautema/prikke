defimpl Plug.Exception, for: DBConnection.ConnectionError do
  def status(_), do: 503
  def actions(_), do: []
end
