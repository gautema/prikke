defmodule Prikke.AnalyticsTest do
  use Prikke.DataCase, async: true

  alias Prikke.Analytics
  import Prikke.AccountsFixtures

  describe "create_pageview/1" do
    test "creates a pageview with valid attributes" do
      user = user_fixture()

      attrs = %{
        path: "/dashboard",
        session_id: "test-session-123",
        referrer: "https://google.com",
        user_agent: "Mozilla/5.0",
        ip_hash: "abc123",
        user_id: user.id
      }

      assert {:ok, pageview} = Analytics.create_pageview(attrs)
      assert pageview.path == "/dashboard"
      assert pageview.session_id == "test-session-123"
      assert pageview.referrer == "https://google.com"
      assert pageview.user_id == user.id
    end

    test "creates a pageview without user_id" do
      attrs = %{
        path: "/",
        session_id: "anonymous-session"
      }

      assert {:ok, pageview} = Analytics.create_pageview(attrs)
      assert pageview.path == "/"
      assert pageview.session_id == "anonymous-session"
      assert pageview.user_id == nil
    end

    test "fails without required fields" do
      assert {:error, changeset} = Analytics.create_pageview(%{})
      assert %{path: ["can't be blank"], session_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "count_pageviews/1" do
    test "counts pageviews since a given time" do
      session_id = Analytics.generate_session_id()

      # Create some pageviews
      Analytics.create_pageview(%{path: "/page1", session_id: session_id})
      Analytics.create_pageview(%{path: "/page2", session_id: session_id})
      Analytics.create_pageview(%{path: "/page3", session_id: session_id})

      since = DateTime.add(DateTime.utc_now(), -1, :hour)
      assert Analytics.count_pageviews(since) == 3
    end

    test "returns 0 when no pageviews" do
      since = DateTime.add(DateTime.utc_now(), -1, :hour)
      assert Analytics.count_pageviews(since) == 0
    end
  end

  describe "count_unique_visitors/1" do
    test "counts unique session_ids" do
      # Create pageviews with different sessions
      Analytics.create_pageview(%{path: "/", session_id: "session-1"})
      Analytics.create_pageview(%{path: "/about", session_id: "session-1"})
      Analytics.create_pageview(%{path: "/", session_id: "session-2"})

      since = DateTime.add(DateTime.utc_now(), -1, :hour)
      assert Analytics.count_unique_visitors(since) == 2
    end
  end

  describe "pageviews_by_path/1" do
    test "groups pageviews by path" do
      session_id = Analytics.generate_session_id()

      Analytics.create_pageview(%{path: "/popular", session_id: session_id})
      Analytics.create_pageview(%{path: "/popular", session_id: session_id})
      Analytics.create_pageview(%{path: "/popular", session_id: session_id})
      Analytics.create_pageview(%{path: "/less-popular", session_id: session_id})

      since = DateTime.add(DateTime.utc_now(), -1, :hour)
      result = Analytics.pageviews_by_path(since)

      assert [{"/popular", 3}, {"/less-popular", 1}] = result
    end
  end

  describe "hash_ip/1" do
    test "hashes an IP address" do
      hash = Analytics.hash_ip("192.168.1.1")
      assert is_binary(hash)
      assert String.length(hash) == 16

      # Same IP produces same hash
      assert Analytics.hash_ip("192.168.1.1") == hash

      # Different IP produces different hash
      refute Analytics.hash_ip("192.168.1.2") == hash
    end

    test "returns nil for non-binary input" do
      assert Analytics.hash_ip(nil) == nil
      assert Analytics.hash_ip(123) == nil
    end
  end

  describe "generate_session_id/0" do
    test "generates a unique session ID" do
      session1 = Analytics.generate_session_id()
      session2 = Analytics.generate_session_id()

      assert is_binary(session1)
      assert is_binary(session2)
      refute session1 == session2
    end
  end

  describe "get_pageview_stats/0" do
    test "returns comprehensive stats" do
      session_id = Analytics.generate_session_id()
      Analytics.create_pageview(%{path: "/", session_id: session_id})
      Analytics.create_pageview(%{path: "/about", session_id: session_id})

      stats = Analytics.get_pageview_stats()

      assert is_integer(stats.today)
      assert is_integer(stats.today_unique)
      assert is_integer(stats.seven_days)
      assert is_integer(stats.seven_days_unique)
      assert is_integer(stats.thirty_days)
      assert is_integer(stats.thirty_days_unique)
      assert is_list(stats.top_pages)
      assert is_list(stats.daily_trend)
    end
  end
end
