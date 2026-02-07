defmodule Prikke.TasksFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Prikke.Tasks` context.
  """

  import Prikke.AccountsFixtures, only: [organization_fixture: 0]

  @doc """
  Generate a cron task.
  """
  def task_fixture(org \\ nil, attrs \\ %{})

  def task_fixture(nil, attrs) do
    task_fixture(organization_fixture(), attrs)
  end

  def task_fixture(org, attrs) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Task #{System.unique_integer([:positive])}",
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

    {:ok, task} = Prikke.Tasks.create_task(org, attrs)
    task
  end

  @doc """
  Generate a one-time task.
  """
  def once_task_fixture(org \\ nil, attrs \\ %{})

  def once_task_fixture(nil, attrs) do
    once_task_fixture(organization_fixture(), attrs)
  end

  def once_task_fixture(org, attrs) do
    scheduled_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    attrs =
      Enum.into(attrs, %{
        name: "One-time Task #{System.unique_integer([:positive])}",
        url: "https://example.com/webhook",
        method: "GET",
        schedule_type: "once",
        scheduled_at: scheduled_at,
        timezone: "UTC",
        enabled: true
      })

    {:ok, task} = Prikke.Tasks.create_task(org, attrs)
    task
  end
end
