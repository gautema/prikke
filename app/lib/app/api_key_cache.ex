defmodule Prikke.ApiKeyCache do
  @moduledoc """
  ETS-based cache for API key lookups.

  Every API request does 2 DB queries (get_by + preload) just for auth.
  This cache stores the result so subsequent requests with the same key
  hit ETS instead of Postgres.

  - TTL: 60 seconds (checked on read)
  - Periodic cleanup every 60s to evict expired entries
  - Public API: `lookup/1`, `put/4`, `invalidate/1`, `invalidate_org/1`
  """

  use GenServer

  @table :api_key_cache
  @ttl_seconds 60
  @cleanup_interval 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Looks up a cached API key by key_id.

  Returns `{:ok, key_hash, organization, api_key_name}` if found and fresh,
  or `:miss` if not cached or expired.
  """
  def lookup(key_id) do
    case :ets.lookup(@table, key_id) do
      [{^key_id, {key_hash, organization, api_key_name, cached_at}}] ->
        if fresh?(cached_at) do
          {:ok, key_hash, organization, api_key_name}
        else
          :ets.delete(@table, key_id)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Caches an API key lookup result.
  """
  def put(key_id, key_hash, organization, api_key_name) do
    :ets.insert(@table, {key_id, {key_hash, organization, api_key_name, System.monotonic_time(:second)}})
    :ok
  end

  @doc """
  Check if last_used_at should be written to DB (debounce 5 min).
  Returns true if we should write, false to skip.
  """
  def should_update_last_used?(key_id) do
    now = System.monotonic_time(:second)

    case :ets.lookup(:api_key_last_used, key_id) do
      [{^key_id, last_written}] when now - last_written < 300 ->
        false

      _ ->
        :ets.insert(:api_key_last_used, {key_id, now})
        true
    end
  end

  @doc """
  Invalidates a cached API key by key_id.
  """
  def invalidate(key_id) do
    :ets.delete(@table, key_id)
    :ok
  end

  @doc """
  Invalidates all cached entries for an organization.
  """
  def invalidate_org(org_id) do
    :ets.tab2list(@table)
    |> Enum.each(fn {key_id, {_hash, org, _name, _at}} ->
      if org.id == org_id, do: :ets.delete(@table, key_id)
    end)

    :ok
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(:api_key_last_used, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    :ets.tab2list(@table)
    |> Enum.each(fn {key_id, {_hash, _org, _name, cached_at}} ->
      unless fresh?(cached_at), do: :ets.delete(@table, key_id)
    end)
  end

  defp fresh?(cached_at) do
    System.monotonic_time(:second) - cached_at < @ttl_seconds
  end
end
