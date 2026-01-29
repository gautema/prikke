defmodule Prikke.StatusMonitorTest do
  use Prikke.DataCase

  alias Prikke.StatusMonitor
  alias Prikke.Status

  describe "check_now/0" do
    test "updates status checks for all components" do
      # Start the monitor in test mode (no automatic checks)
      {:ok, _pid} = StatusMonitor.start_link(test_mode: true)

      # Manually trigger a check
      :ok = StatusMonitor.check_now()

      # Verify all components were checked
      status = Status.get_current_status()

      # API should always be up since the monitor is running
      assert status["api"].status == "up"

      # Scheduler and workers will be down in test because those processes aren't started
      # but the checks should exist
      assert Map.has_key?(status, "scheduler")
      assert Map.has_key?(status, "workers")
    end
  end
end
