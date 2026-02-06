defmodule Prikke.Emails do
  @moduledoc """
  The Emails context.
  Handles email log tracking.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo
  alias Prikke.Emails.EmailLog

  @doc """
  Inserts a new email log entry.
  """
  def log_email(attrs) do
    %EmailLog{}
    |> EmailLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns recent email logs, ordered by most recent first.
  """
  def list_recent_emails(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(e in EmailLog,
      order_by: [desc: e.inserted_at],
      limit: ^limit,
      preload: [:organization]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of emails sent today (UTC).
  """
  def count_emails_today do
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    from(e in EmailLog, where: e.inserted_at >= ^today_start)
    |> Repo.aggregate(:count)
  end
end
