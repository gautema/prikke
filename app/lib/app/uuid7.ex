defmodule Prikke.UUID7 do
  @moduledoc """
  Custom Ecto type for UUID v7 (time-ordered UUIDs).

  UUID v7 embeds a Unix timestamp in the first 48 bits, making IDs:
  - Roughly sortable by creation time
  - Better for B-tree index performance (no random page splits)
  - Compatible with standard UUID format (same size, same column type)

  Uses the `uniq` library for generation.
  """

  use Ecto.Type

  @doc """
  The underlying Postgres type is uuid.
  """
  def type, do: :uuid

  @doc """
  Cast user input to UUID format.
  """
  def cast(uuid), do: Ecto.UUID.cast(uuid)

  @doc """
  Load UUID from database.
  """
  def load(uuid), do: Ecto.UUID.load(uuid)

  @doc """
  Dump UUID to database format.
  """
  def dump(uuid), do: Ecto.UUID.dump(uuid)

  @doc """
  Generate a new UUID v7.
  """
  def generate, do: Uniq.UUID.uuid7()

  @doc """
  Called by Ecto when autogenerate: true is set.
  """
  def autogenerate, do: generate()
end
