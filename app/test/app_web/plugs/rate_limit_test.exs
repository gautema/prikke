defmodule PrikkeWeb.RateLimitTest do
  use PrikkeWeb.ConnCase, async: false

  import Prikke.AccountsFixtures

  # Limit is 1000/min in test config
  @limit 1000

  setup do
    # Clear rate limit storage between tests
    :ets.delete_all_objects(PrikkeWeb.RateLimit.Storage)
    :ok
  end

  describe "rate limiting" do
    setup do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      {:ok, api_key, raw_secret} = Prikke.Accounts.create_api_key(org, user, %{name: "test"})
      auth_token = "#{api_key.key_id}.#{raw_secret}"
      %{api_key: api_key, auth_token: auth_token}
    end

    test "allows requests under the limit", %{conn: conn, auth_token: auth_token} do
      # Make a few requests - should all succeed
      for _ <- 1..3 do
        response =
          conn
          |> put_req_header("authorization", "Bearer #{auth_token}")
          |> get(~p"/api/v1/jobs")

        assert response.status == 200
      end
    end

    @tag :slow
    test "returns 429 when rate limit exceeded", %{conn: conn, auth_token: auth_token} do
      # Make limit + 1 requests
      statuses =
        for _ <- 1..(@limit + 1) do
          conn
          |> put_req_header("authorization", "Bearer #{auth_token}")
          |> get(~p"/api/v1/jobs")
          |> Map.get(:status)
        end

      # First @limit should succeed, last should be rate limited
      assert Enum.count(statuses, &(&1 == 200)) == @limit
      assert Enum.count(statuses, &(&1 == 429)) == 1
    end

    @tag :slow
    test "returns JSON error on rate limit", %{conn: conn, auth_token: auth_token} do
      # Exhaust the limit
      for _ <- 1..@limit do
        conn
        |> put_req_header("authorization", "Bearer #{auth_token}")
        |> get(~p"/api/v1/jobs")
      end

      # Next request should be rate limited with JSON error
      response =
        conn
        |> put_req_header("authorization", "Bearer #{auth_token}")
        |> get(~p"/api/v1/jobs")

      assert response.status == 429

      assert Jason.decode!(response.resp_body) == %{
               "error" => "Rate limit exceeded. Try again later."
             }
    end
  end
end
