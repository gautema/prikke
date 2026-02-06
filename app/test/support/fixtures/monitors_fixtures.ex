defmodule Prikke.MonitorsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Prikke.Monitors` context.
  """

  import Prikke.AccountsFixtures, only: [organization_fixture: 0]

  def monitor_fixture(org \\ nil, attrs \\ %{})

  def monitor_fixture(nil, attrs) do
    monitor_fixture(organization_fixture(), attrs)
  end

  def monitor_fixture(org, attrs) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Monitor #{System.unique_integer([:positive])}",
        schedule_type: "interval",
        interval_seconds: 3600,
        grace_period_seconds: 300,
        enabled: true
      })

    {:ok, monitor} = Prikke.Monitors.create_monitor(org, attrs)
    monitor
  end

  def cron_monitor_fixture(org \\ nil, attrs \\ %{})

  def cron_monitor_fixture(nil, attrs) do
    cron_monitor_fixture(organization_fixture(), attrs)
  end

  def cron_monitor_fixture(org, attrs) do
    attrs =
      Enum.into(attrs, %{
        name: "Cron Monitor #{System.unique_integer([:positive])}",
        schedule_type: "cron",
        cron_expression: "0 * * * *",
        grace_period_seconds: 300,
        enabled: true
      })

    {:ok, monitor} = Prikke.Monitors.create_monitor(org, attrs)
    monitor
  end
end
