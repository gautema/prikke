defmodule Prikke.Executions.Execution do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "executions" do
    field :status, :string, default: "pending"
    field :scheduled_for, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :status_code, :integer
    field :duration_ms, :integer
    field :response_body, :string
    field :error_message, :string
    field :attempt, :integer, default: 1

    belongs_to :job, Prikke.Jobs.Job

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(pending running success failed timeout)

  @doc false
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :job_id,
      :status,
      :scheduled_for,
      :started_at,
      :finished_at,
      :status_code,
      :duration_ms,
      :response_body,
      :error_message,
      :attempt
    ])
    |> validate_required([:job_id, :scheduled_for])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:job_id)
  end

  @doc """
  Changeset for creating a new pending execution.
  """
  def create_changeset(execution, attrs) do
    execution
    |> cast(attrs, [:job_id, :scheduled_for, :attempt])
    |> validate_required([:job_id, :scheduled_for])
    |> put_change(:status, "pending")
    |> foreign_key_constraint(:job_id)
  end

  @doc """
  Changeset for marking an execution as started (running).
  """
  def start_changeset(execution) do
    execution
    |> change(%{
      status: "running",
      started_at: DateTime.utc_now(:second)
    })
  end

  @doc """
  Changeset for completing an execution with success.
  """
  def complete_changeset(execution, attrs) do
    now = DateTime.utc_now(:second)
    duration = if execution.started_at, do: DateTime.diff(now, execution.started_at, :millisecond), else: nil

    execution
    |> cast(attrs, [:status_code, :response_body])
    |> put_change(:status, "success")
    |> put_change(:finished_at, now)
    |> put_change(:duration_ms, duration)
  end

  @doc """
  Changeset for marking an execution as failed.
  """
  def fail_changeset(execution, attrs) do
    now = DateTime.utc_now(:second)
    duration = if execution.started_at, do: DateTime.diff(now, execution.started_at, :millisecond), else: nil

    execution
    |> cast(attrs, [:status_code, :response_body, :error_message])
    |> put_change(:status, "failed")
    |> put_change(:finished_at, now)
    |> put_change(:duration_ms, duration)
  end

  @doc """
  Changeset for marking an execution as timed out.
  """
  def timeout_changeset(execution) do
    now = DateTime.utc_now(:second)
    duration = if execution.started_at, do: DateTime.diff(now, execution.started_at, :millisecond), else: nil

    execution
    |> change(%{
      status: "timeout",
      finished_at: now,
      duration_ms: duration,
      error_message: "Request timed out"
    })
  end
end
