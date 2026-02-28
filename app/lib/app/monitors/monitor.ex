defmodule Prikke.Monitors.Monitor do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "monitors" do
    field :name, :string
    field :ping_token, :string
    field :schedule_type, :string
    field :cron_expression, :string
    field :interval_seconds, :integer
    field :grace_period_seconds, :integer, default: 300
    field :status, :string, default: "new"
    field :last_ping_at, :utc_datetime
    field :next_expected_at, :utc_datetime
    field :enabled, :boolean, default: true
    field :notify_on_failure, :boolean
    field :notify_on_recovery, :boolean

    belongs_to :organization, Prikke.Accounts.Organization
    has_many :pings, Prikke.Monitors.MonitorPing

    timestamps(type: :utc_datetime)
  end

  @schedule_types ~w(cron interval)

  def changeset(monitor, attrs) do
    monitor
    |> cast(attrs, [
      :name,
      :schedule_type,
      :cron_expression,
      :interval_seconds,
      :grace_period_seconds,
      :enabled,
      :notify_on_failure,
      :notify_on_recovery
    ])
    |> validate_required([:name, :schedule_type])
    |> validate_inclusion(:schedule_type, @schedule_types)
    |> validate_number(:grace_period_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 3600
    )
    |> validate_schedule()
  end

  def create_changeset(monitor, attrs, organization_id) do
    monitor
    |> changeset(attrs)
    |> put_change(:organization_id, organization_id)
    |> put_change(:ping_token, generate_ping_token())
    |> put_change(:status, "new")
    |> validate_required([:organization_id, :ping_token])
    |> unique_constraint(:ping_token)
  end

  defp validate_schedule(changeset) do
    case get_field(changeset, :schedule_type) do
      "cron" ->
        changeset
        |> validate_required([:cron_expression])
        |> validate_cron_expression()

      "interval" ->
        changeset
        |> validate_required([:interval_seconds])
        |> validate_number(:interval_seconds,
          greater_than_or_equal_to: 60,
          less_than_or_equal_to: 604_800
        )

      _ ->
        changeset
    end
  end

  defp validate_cron_expression(changeset) do
    validate_change(changeset, :cron_expression, fn _, expression ->
      case Crontab.CronExpression.Parser.parse(expression) do
        {:ok, _} -> []
        {:error, _} -> [cron_expression: "is not a valid cron expression"]
      end
    end)
  end

  defp generate_ping_token do
    "pm_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64() |> binary_part(0, 32))
  end

  @doc """
  Computes the next expected ping time after a ping is received.
  """
  def compute_next_expected_at(monitor, ping_time) do
    case monitor.schedule_type do
      "cron" ->
        case Crontab.CronExpression.Parser.parse(monitor.cron_expression) do
          {:ok, cron} ->
            case Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(ping_time)) do
              {:ok, naive_next} -> DateTime.from_naive!(naive_next, "Etc/UTC")
              {:error, _} -> nil
            end

          {:error, _} ->
            nil
        end

      "interval" ->
        DateTime.add(ping_time, monitor.interval_seconds, :second)
    end
  end
end
