defmodule Prikke.Analytics do
  @moduledoc """
  The Analytics context.
  Handles pageview tracking and analytics queries.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo
  alias Prikke.Analytics.Pageview

  @doc """
  Creates a pageview record.
  """
  def create_pageview(attrs) do
    %Pageview{}
    |> Pageview.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a pageview asynchronously to avoid blocking requests.
  """
  def track_pageview_async(attrs) do
    Task.start(fn -> create_pageview(attrs) end)
  end

  @doc """
  Counts total pageviews since a given datetime.
  """
  def count_pageviews(since) do
    from(p in Pageview,
      where: p.inserted_at >= ^since
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts unique visitors (unique session_ids) since a given datetime.
  """
  def count_unique_visitors(since) do
    from(p in Pageview,
      where: p.inserted_at >= ^since,
      select: count(p.session_id, :distinct)
    )
    |> Repo.one()
  end

  @doc """
  Gets pageviews grouped by path since a given datetime.
  Returns a list of {path, count} tuples, sorted by count descending.
  """
  def pageviews_by_path(since, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(p in Pageview,
      where: p.inserted_at >= ^since,
      group_by: p.path,
      select: {p.path, count(p.id)},
      order_by: [desc: count(p.id)],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Gets pageviews grouped by day for the last N days.
  Returns a list of {date, count} tuples.
  """
  def pageviews_by_day(days) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)

    from(p in Pageview,
      where: p.inserted_at >= ^since,
      group_by: fragment("DATE(?)", p.inserted_at),
      select: {fragment("DATE(?)", p.inserted_at), count(p.id)},
      order_by: [asc: fragment("DATE(?)", p.inserted_at)]
    )
    |> Repo.all()
  end

  @doc """
  Gets pageview stats for the superadmin dashboard.
  """
  def get_pageview_stats do
    now = DateTime.utc_now()
    today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    seven_days_ago = DateTime.add(now, -7, :day)
    thirty_days_ago = DateTime.add(now, -30, :day)

    %{
      today: count_pageviews(today),
      today_unique: count_unique_visitors(today),
      seven_days: count_pageviews(seven_days_ago),
      seven_days_unique: count_unique_visitors(seven_days_ago),
      thirty_days: count_pageviews(thirty_days_ago),
      thirty_days_unique: count_unique_visitors(thirty_days_ago),
      top_pages: pageviews_by_path(seven_days_ago, limit: 10),
      daily_trend: pageviews_by_day(14)
    }
  end

  @doc """
  Hashes an IP address for privacy-preserving tracking.
  Uses SHA256 with a salt.
  """
  def hash_ip(ip) when is_binary(ip) do
    salt = Application.get_env(:app, :ip_hash_salt, "runlater-default-salt")
    :crypto.hash(:sha256, ip <> salt) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  def hash_ip(_), do: nil

  @doc """
  Generates a new session ID.
  """
  def generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
