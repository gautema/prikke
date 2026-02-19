defmodule Prikke.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Prikke.UUID7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tasks" do
    field :name, :string
    field :url, :string
    field :method, :string, default: "GET"
    field :headers, :map, default: %{}
    field :body, :string
    field :schedule_type, :string
    field :cron_expression, :string
    field :interval_minutes, :integer
    field :scheduled_at, :utc_datetime
    field :enabled, :boolean, default: true
    field :retry_attempts, :integer, default: 3
    field :timeout_ms, :integer, default: 30000
    field :next_run_at, :utc_datetime
    field :callback_url, :string
    field :expected_status_codes, :string
    field :expected_body_pattern, :string
    field :queue, :string
    field :last_execution_at, :utc_datetime
    field :last_execution_status, :string
    field :badge_token, :string
    field :notify_on_failure, :boolean
    field :notify_on_recovery, :boolean
    field :deleted_at, :utc_datetime

    # Virtual field for form editing
    field :headers_json, :string, virtual: true

    belongs_to :organization, Prikke.Accounts.Organization
    has_many :executions, Prikke.Executions.Execution, foreign_key: :task_id

    timestamps(type: :utc_datetime)
  end

  @http_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @schedule_types ~w(cron once)

  @doc false
  def changeset(task, attrs, opts \\ []) do
    skip_ssrf = Keyword.get(opts, :skip_ssrf, false)
    skip_next_run = Keyword.get(opts, :skip_next_run, false)

    cs =
      task
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
        :enabled,
        :retry_attempts,
        :timeout_ms,
        :callback_url,
        :expected_status_codes,
        :expected_body_pattern,
        :queue,
        :notify_on_failure,
        :notify_on_recovery
      ])
      |> trim_url()
      |> maybe_generate_name()
      |> validate_required([:url, :schedule_type])
      |> validate_inclusion(:method, @http_methods)
      |> validate_inclusion(:schedule_type, @schedule_types)
      |> validate_url(:url)
      |> validate_callback_url()

    cs = if skip_ssrf, do: cs, else: Prikke.UrlValidator.validate_webhook_url_safe(cs, :url)

    cs
    |> validate_number(:retry_attempts, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1000,
      less_than_or_equal_to: 300_000
    )
    |> validate_body_size()
    |> validate_expected_status_codes()
    |> validate_schedule()
    |> compute_interval_minutes()
    |> then(fn cs -> if skip_next_run, do: cs, else: compute_next_run_at(cs) end)
  end

  @doc """
  Changeset for creating a task within an organization.
  """
  def create_changeset(task, attrs, organization_id, opts \\ []) do
    task
    |> changeset(attrs, opts)
    |> put_change(:organization_id, organization_id)
    |> validate_required([:organization_id])
  end

  defp trim_url(changeset) do
    case get_change(changeset, :url) do
      nil -> changeset
      url -> put_change(changeset, :url, String.trim(url))
    end
  end

  defp maybe_generate_name(changeset) do
    name = get_field(changeset, :name)
    url = get_field(changeset, :url)

    if (is_nil(name) or name == "") and is_binary(url) and url != "" do
      host = url |> URI.parse() |> Map.get(:host) |> to_string()
      put_change(changeset, :name, host)
    else
      changeset
    end
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

  defp validate_callback_url(changeset) do
    validate_change(changeset, :callback_url, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
          []

        _ ->
          [{:callback_url, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end

  # Max body size: 256KB
  @max_body_size 256 * 1024

  defp validate_body_size(changeset) do
    validate_change(changeset, :body, fn _, body ->
      if is_binary(body) and byte_size(body) > @max_body_size do
        [{:body, "must be less than 256KB"}]
      else
        []
      end
    end)
  end

  defp validate_expected_status_codes(changeset) do
    validate_change(changeset, :expected_status_codes, fn _, codes ->
      codes
      |> String.split(",", trim: true)
      |> Enum.reduce([], fn code_str, errors ->
        code_str = String.trim(code_str)

        case Integer.parse(code_str) do
          {code, ""} when code >= 100 and code <= 599 ->
            errors

          _ ->
            [{:expected_status_codes, "must be comma-separated HTTP status codes (100-599)"}]
        end
      end)
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
      # Allow a small window for immediate tasks and form submission lag
      cutoff = DateTime.add(DateTime.utc_now(), -300, :second)

      if DateTime.compare(scheduled_at, cutoff) == :gt do
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
      # One-time tasks don't have interval
      put_change(changeset, :interval_minutes, nil)
    end
  end

  # Estimate the interval in minutes from a cron expression
  # This is used for task priority (minute tasks > hourly > daily)
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
          # One-time tasks run at scheduled_at
          scheduled_at = get_field(changeset, :scheduled_at)
          put_change(changeset, :next_run_at, scheduled_at)

        _ ->
          changeset
      end
    else
      # Disabled tasks don't have a next run
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
  Computes the next run time for a cron task after it has been scheduled.
  Called by the scheduler after creating an execution.
  """
  def advance_next_run_changeset(task) do
    case task.schedule_type do
      "cron" ->
        case Crontab.CronExpression.Parser.parse(task.cron_expression) do
          {:ok, cron} ->
            # Get next run after the current next_run_at (or now if nil)
            reference = task.next_run_at || DateTime.utc_now()

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

                change(task, next_run_at: next_run)

              {:error, _} ->
                change(task, %{})
            end

          {:error, _} ->
            change(task, %{})
        end

      "once" ->
        # One-time tasks don't advance, they get disabled or next_run_at set to nil
        change(task, next_run_at: nil)

      _ ->
        change(task, %{})
    end
  end
end
