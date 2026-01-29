defmodule Prikke.Jobs.Job do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "jobs" do
    field :name, :string
    field :url, :string
    field :method, :string, default: "GET"
    field :headers, :map, default: %{}
    field :body, :string
    field :schedule_type, :string
    field :cron_expression, :string
    field :interval_minutes, :integer
    field :scheduled_at, :utc_datetime
    field :timezone, :string, default: "UTC"
    field :enabled, :boolean, default: true
    field :retry_attempts, :integer, default: 3
    field :timeout_ms, :integer, default: 30000
    field :next_run_at, :utc_datetime

    # Virtual field for form editing
    field :headers_json, :string, virtual: true

    belongs_to :organization, Prikke.Accounts.Organization
    has_many :executions, Prikke.Executions.Execution

    timestamps(type: :utc_datetime)
  end

  @http_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @schedule_types ~w(cron once)

  @doc false
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :name,
      :url,
      :method,
      :headers,
      :headers_json,
      :body,
      :schedule_type,
      :cron_expression,
      :scheduled_at,
      :timezone,
      :enabled,
      :retry_attempts,
      :timeout_ms
    ])
    |> validate_required([:name, :url, :schedule_type])
    |> validate_inclusion(:method, @http_methods)
    |> validate_inclusion(:schedule_type, @schedule_types)
    |> validate_url(:url)
    |> validate_number(:retry_attempts, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1000,
      less_than_or_equal_to: 300_000
    )
    |> validate_schedule()
    |> compute_interval_minutes()
    |> compute_next_run_at()
  end

  @doc """
  Changeset for creating a job within an organization.
  """
  def create_changeset(job, attrs, organization_id) do
    job
    |> changeset(attrs)
    |> put_change(:organization_id, organization_id)
    |> validate_required([:organization_id])
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
          []

        _ ->
          [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end

  defp validate_schedule(changeset) do
    schedule_type = get_field(changeset, :schedule_type)

    case schedule_type do
      "cron" ->
        changeset
        |> validate_required([:cron_expression])
        |> validate_cron_expression()

      "once" ->
        changeset
        |> validate_required([:scheduled_at])
        |> validate_future_date()

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

  defp validate_future_date(changeset) do
    validate_change(changeset, :scheduled_at, fn _, scheduled_at ->
      if DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt do
        []
      else
        [scheduled_at: "must be in the future"]
      end
    end)
  end

  defp compute_interval_minutes(changeset) do
    if get_field(changeset, :schedule_type) == "cron" do
      case get_field(changeset, :cron_expression) do
        nil ->
          changeset

        expression ->
          case Crontab.CronExpression.Parser.parse(expression) do
            {:ok, cron} ->
              interval = estimate_interval_minutes(cron)
              put_change(changeset, :interval_minutes, interval)

            {:error, _} ->
              changeset
          end
      end
    else
      # One-time jobs don't have interval
      put_change(changeset, :interval_minutes, nil)
    end
  end

  # Estimate the interval in minutes from a cron expression
  # This is used for job priority (minute jobs > hourly > daily)
  defp estimate_interval_minutes(%Crontab.CronExpression{} = cron) do
    minute_interval = estimate_minute_interval(cron.minute)

    cond do
      # Every N minutes
      minute_interval < 60 ->
        minute_interval

      # Hourly (minute is fixed, hour is *)
      cron.hour == [:*] ->
        60

      # Step hours like */2
      match?([{:/, :*, step}] when is_integer(step), cron.hour) ->
        [{:/, :*, step}] = cron.hour
        step * 60

      # Multiple times per day
      is_list(cron.hour) and length(cron.hour) > 1 ->
        div(24 * 60, length(cron.hour))

      # Daily or less frequent
      true ->
        24 * 60
    end
  end

  defp estimate_minute_interval([:*]), do: 1
  defp estimate_minute_interval([{:/, :*, step}]) when is_integer(step), do: step

  defp estimate_minute_interval(list) when is_list(list) and length(list) > 1,
    do: div(60, length(list))

  defp estimate_minute_interval(_), do: 60

  defp compute_next_run_at(changeset) do
    # Only compute if enabled
    if get_field(changeset, :enabled) do
      case get_field(changeset, :schedule_type) do
        "cron" ->
          compute_next_cron_run(changeset)

        "once" ->
          # One-time jobs run at scheduled_at
          scheduled_at = get_field(changeset, :scheduled_at)
          put_change(changeset, :next_run_at, scheduled_at)

        _ ->
          changeset
      end
    else
      # Disabled jobs don't have a next run
      put_change(changeset, :next_run_at, nil)
    end
  end

  defp compute_next_cron_run(changeset) do
    case get_field(changeset, :cron_expression) do
      nil ->
        changeset

      expression ->
        case Crontab.CronExpression.Parser.parse(expression) do
          {:ok, cron} ->
            now = DateTime.utc_now()
            # Get next run time from cron expression
            case Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(now)) do
              {:ok, naive_next} ->
                next_run = DateTime.from_naive!(naive_next, "Etc/UTC")
                put_change(changeset, :next_run_at, next_run)

              {:error, _} ->
                changeset
            end

          {:error, _} ->
            changeset
        end
    end
  end

  @doc """
  Computes the next run time for a cron job after it has been scheduled.
  Called by the scheduler after creating an execution.
  """
  def advance_next_run_changeset(job) do
    case job.schedule_type do
      "cron" ->
        case Crontab.CronExpression.Parser.parse(job.cron_expression) do
          {:ok, cron} ->
            # Get next run after the current next_run_at (or now if nil)
            reference = job.next_run_at || DateTime.utc_now()

            case Crontab.Scheduler.get_next_run_date(cron, DateTime.to_naive(reference)) do
              {:ok, naive_next} ->
                next_run = DateTime.from_naive!(naive_next, "Etc/UTC")
                # If next_run equals current, add 1 minute and recalculate
                next_run =
                  if DateTime.compare(next_run, reference) != :gt do
                    reference_plus_one = DateTime.add(reference, 60, :second)

                    case Crontab.Scheduler.get_next_run_date(
                           cron,
                           DateTime.to_naive(reference_plus_one)
                         ) do
                      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
                      _ -> next_run
                    end
                  else
                    next_run
                  end

                change(job, next_run_at: next_run)

              {:error, _} ->
                change(job, %{})
            end

          {:error, _} ->
            change(job, %{})
        end

      "once" ->
        # One-time jobs don't advance, they get disabled or next_run_at set to nil
        change(job, next_run_at: nil)

      _ ->
        change(job, %{})
    end
  end
end
