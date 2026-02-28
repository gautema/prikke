defmodule Prikke.Queues do
  @moduledoc """
  Context for managing queues and their pause/resume state.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo
  alias Prikke.Queues.Queue
  alias Prikke.Accounts.Organization

  @doc """
  Gets or creates a queue record, then sets paused = true.
  """
  def pause_queue(%Organization{} = org, queue_name) when is_binary(queue_name) do
    queue = get_or_create_queue!(org, queue_name)

    queue
    |> Queue.changeset(%{paused: true})
    |> Repo.update()
  end

  @doc """
  Resumes a queue by setting paused = false.
  Returns :ok if queue doesn't exist (nothing to resume).
  """
  def resume_queue(%Organization{} = org, queue_name) when is_binary(queue_name) do
    case get_queue(org, queue_name) do
      nil ->
        :ok

      queue ->
        queue
        |> Queue.changeset(%{paused: false})
        |> Repo.update()
    end
  end

  @doc """
  Returns a list of paused queue names for an organization.
  """
  def list_paused_queues(%Organization{} = org) do
    from(q in Queue,
      where: q.organization_id == ^org.id and q.paused == true,
      select: q.name,
      order_by: q.name
    )
    |> Repo.all()
  end

  @doc """
  Returns true if the given queue is paused for the organization.
  """
  def queue_paused?(%Organization{} = org, queue_name) when is_binary(queue_name) do
    from(q in Queue,
      where: q.organization_id == ^org.id and q.name == ^queue_name and q.paused == true
    )
    |> Repo.exists?()
  end

  @doc """
  Returns all queues for an organization with their pause status.
  Merges queue records with distinct queue names from tasks.
  Returns a list of `{queue_name, :active | :paused}` tuples.
  """
  def list_queues_with_status(%Organization{} = org) do
    task_queues = Prikke.Tasks.list_queues(org)
    paused = MapSet.new(list_paused_queues(org))

    Enum.map(task_queues, fn queue_name ->
      status = if MapSet.member?(paused, queue_name), do: :paused, else: :active
      {queue_name, status}
    end)
  end

  @doc """
  Gets a queue record by org and name.
  """
  def get_queue(%Organization{} = org, queue_name) do
    from(q in Queue,
      where: q.organization_id == ^org.id and q.name == ^queue_name
    )
    |> Repo.one()
  end

  @doc """
  Gets a queue by ID within an organization.
  """
  def get_queue!(%Organization{} = org, queue_id) do
    from(q in Queue,
      where: q.organization_id == ^org.id and q.id == ^queue_id
    )
    |> Repo.one!()
  end

  @doc """
  Ensures queue records exist for all task-referenced queues.
  Creates Queue records for any queue name found in tasks but missing from the queues table.
  """
  def ensure_queues_exist(%Organization{} = org) do
    task_queues = Prikke.Tasks.list_queues(org)

    Enum.each(task_queues, fn queue_name ->
      get_or_create_queue!(org, queue_name)
    end)
  end

  @doc """
  Lists all queues for an organization.
  """
  def list_queues(%Organization{} = org) do
    from(q in Queue,
      where: q.organization_id == ^org.id,
      order_by: [asc: q.name]
    )
    |> Repo.all()
  end

  @doc """
  Gets or creates a queue record.
  """
  def get_or_create_queue!(%Organization{} = org, queue_name) do
    case get_queue(org, queue_name) do
      nil ->
        {:ok, queue} =
          %Queue{}
          |> Queue.changeset(%{organization_id: org.id, name: queue_name})
          |> Repo.insert()

        queue

      queue ->
        queue
    end
  end
end
