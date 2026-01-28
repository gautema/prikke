defmodule Prikke.Jobs do
  @moduledoc """
  The Jobs context.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Jobs.Job
  alias Prikke.Accounts.Organization

  @doc """
  Subscribes to notifications about job changes for an organization.

  The broadcasted messages match the pattern:

    * {:created, %Job{}}
    * {:updated, %Job{}}
    * {:deleted, %Job{}}

  """
  def subscribe_jobs(%Organization{} = org) do
    Phoenix.PubSub.subscribe(Prikke.PubSub, "org:#{org.id}:jobs")
  end

  defp broadcast(%Organization{} = org, message) do
    Phoenix.PubSub.broadcast(Prikke.PubSub, "org:#{org.id}:jobs", message)
  end

  @doc """
  Returns the list of jobs for an organization.

  ## Examples

      iex> list_jobs(organization)
      [%Job{}, ...]

  """
  def list_jobs(%Organization{} = org) do
    Job
    |> where(organization_id: ^org.id)
    |> order_by([j], desc: j.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns enabled jobs for an organization.
  """
  def list_enabled_jobs(%Organization{} = org) do
    Job
    |> where(organization_id: ^org.id)
    |> where(enabled: true)
    |> order_by([j], desc: j.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single job.

  Raises `Ecto.NoResultsError` if the Job does not exist.

  ## Examples

      iex> get_job!(organization, 123)
      %Job{}

      iex> get_job!(organization, 456)
      ** (Ecto.NoResultsError)

  """
  def get_job!(%Organization{} = org, id) do
    Job
    |> where(organization_id: ^org.id)
    |> Repo.get!(id)
  end

  @doc """
  Gets a single job, returns nil if not found.
  """
  def get_job(%Organization{} = org, id) do
    Job
    |> where(organization_id: ^org.id)
    |> Repo.get(id)
  end

  @doc """
  Creates a job for an organization.

  ## Examples

      iex> create_job(organization, %{field: value})
      {:ok, %Job{}}

      iex> create_job(organization, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_job(%Organization{} = org, attrs) do
    with {:ok, job} <-
           %Job{}
           |> Job.create_changeset(attrs, org.id)
           |> Repo.insert() do
      broadcast(org, {:created, job})
      {:ok, job}
    end
  end

  @doc """
  Updates a job.

  ## Examples

      iex> update_job(organization, job, %{field: new_value})
      {:ok, %Job{}}

      iex> update_job(organization, job, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_job(%Organization{} = org, %Job{} = job, attrs) do
    if job.organization_id != org.id do
      raise ArgumentError, "job does not belong to organization"
    end

    with {:ok, job} <-
           job
           |> Job.changeset(attrs)
           |> Repo.update() do
      broadcast(org, {:updated, job})
      {:ok, job}
    end
  end

  @doc """
  Deletes a job.

  ## Examples

      iex> delete_job(organization, job)
      {:ok, %Job{}}

      iex> delete_job(organization, job)
      {:error, %Ecto.Changeset{}}

  """
  def delete_job(%Organization{} = org, %Job{} = job) do
    if job.organization_id != org.id do
      raise ArgumentError, "job does not belong to organization"
    end

    with {:ok, job} <- Repo.delete(job) do
      broadcast(org, {:deleted, job})
      {:ok, job}
    end
  end

  @doc """
  Toggles a job's enabled status.
  """
  def toggle_job(%Organization{} = org, %Job{} = job) do
    update_job(org, job, %{enabled: !job.enabled})
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking job changes.

  ## Examples

      iex> change_job(job)
      %Ecto.Changeset{data: %Job{}}

  """
  def change_job(%Job{} = job, attrs \\ %{}) do
    Job.changeset(job, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for creating a new job.
  """
  def change_new_job(%Organization{} = org, attrs \\ %{}) do
    Job.create_changeset(%Job{}, attrs, org.id)
  end

  @doc """
  Counts jobs for an organization.
  """
  def count_jobs(%Organization{} = org) do
    Job
    |> where(organization_id: ^org.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts enabled jobs for an organization.
  """
  def count_enabled_jobs(%Organization{} = org) do
    Job
    |> where(organization_id: ^org.id)
    |> where(enabled: true)
    |> Repo.aggregate(:count)
  end
end
