defmodule Prikke.JobsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Prikke.Jobs` context.
  """

  import Prikke.AccountsFixtures, only: [organization_fixture: 0]

  @doc """
  Generate a cron job.
  """
  def job_fixture(org \\ nil, attrs \\ %{})

  def job_fixture(nil, attrs) do
    job_fixture(organization_fixture(), attrs)
  end

  def job_fixture(org, attrs) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Job #{System.unique_integer([:positive])}",
        url: "https://example.com/webhook",
        method: "POST",
        headers: %{"Content-Type" => "application/json"},
        body: ~s({"test": true}),
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        timezone: "UTC",
        enabled: true,
        retry_attempts: 3,
        timeout_ms: 30000
      })

    {:ok, job} = Prikke.Jobs.create_job(org, attrs)
    job
  end

  @doc """
  Generate a one-time job.
  """
  def once_job_fixture(org \\ nil, attrs \\ %{})

  def once_job_fixture(nil, attrs) do
    once_job_fixture(organization_fixture(), attrs)
  end

  def once_job_fixture(org, attrs) do
    # Schedule for 1 hour in the future
    scheduled_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    attrs =
      Enum.into(attrs, %{
        name: "One-time Job #{System.unique_integer([:positive])}",
        url: "https://example.com/webhook",
        method: "GET",
        schedule_type: "once",
        scheduled_at: scheduled_at,
        timezone: "UTC",
        enabled: true
      })

    {:ok, job} = Prikke.Jobs.create_job(org, attrs)
    job
  end
end
