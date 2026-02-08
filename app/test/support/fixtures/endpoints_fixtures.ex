defmodule Prikke.EndpointsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Prikke.Endpoints` context.
  """

  import Prikke.AccountsFixtures, only: [organization_fixture: 0]

  def endpoint_fixture(org \\ nil, attrs \\ %{})

  def endpoint_fixture(nil, attrs) do
    endpoint_fixture(organization_fixture(), attrs)
  end

  def endpoint_fixture(org, attrs) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Endpoint #{System.unique_integer([:positive])}",
        forward_url: "https://example.com/webhooks/test",
        enabled: true
      })

    {:ok, endpoint} = Prikke.Endpoints.create_endpoint(org, attrs)
    endpoint
  end
end
