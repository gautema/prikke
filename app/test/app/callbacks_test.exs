defmodule Prikke.CallbacksTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures

  alias Prikke.Callbacks
  alias Prikke.Executions
  alias Prikke.Jobs

  describe "build_payload/1" do
    setup do
      user = user_fixture()
      {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, job} =
        Jobs.create_job(org, %{
          name: "Test Job",
          url: "https://example.com/webhook",
          schedule_type: "cron",
          cron_expression: "0 * * * *"
        })

      %{organization: org, job: job}
    end

    test "builds correct payload structure", %{job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()

      {:ok, completed} =
        Executions.complete_execution(running, %{
          status_code: 200,
          response_body: "OK",
          duration_ms: 150
        })

      payload = Callbacks.build_payload(completed)

      assert payload.event == "execution.completed"
      assert payload.job_id == job.id
      assert payload.execution_id == completed.id
      assert payload.status == "success"
      assert payload.status_code == 200
      assert payload.duration_ms == 150
      assert payload.response_body == "OK"
      assert payload.error_message == nil
      assert payload.attempt == 1
      assert payload.scheduled_for != nil
      assert payload.finished_at != nil
    end

    test "includes error details for failed executions", %{job: job} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _execution} = Executions.create_execution_for_job(job, past)
      {:ok, running} = Executions.claim_next_execution()

      {:ok, failed} =
        Executions.fail_execution(running, %{
          status_code: 500,
          error_message: "Internal Server Error",
          duration_ms: 200
        })

      payload = Callbacks.build_payload(failed)

      assert payload.status == "failed"
      assert payload.status_code == 500
      assert payload.error_message == "Internal Server Error"
    end
  end

  describe "resolve_callback_url/1" do
    test "returns execution callback_url when set" do
      execution = %Prikke.Executions.Execution{
        callback_url: "https://example.com/exec-callback",
        job: %Prikke.Jobs.Job{callback_url: "https://example.com/job-callback"}
      }

      assert Callbacks.resolve_callback_url(execution) == "https://example.com/exec-callback"
    end

    test "falls back to job callback_url when execution has none" do
      execution = %Prikke.Executions.Execution{
        callback_url: nil,
        job: %Prikke.Jobs.Job{callback_url: "https://example.com/job-callback"}
      }

      assert Callbacks.resolve_callback_url(execution) == "https://example.com/job-callback"
    end

    test "returns nil when neither has callback_url" do
      execution = %Prikke.Executions.Execution{
        callback_url: nil,
        job: %Prikke.Jobs.Job{callback_url: nil}
      }

      assert Callbacks.resolve_callback_url(execution) == nil
    end
  end

  describe "send_callback/1" do
    test "returns :noop when no callback_url is configured" do
      execution = %Prikke.Executions.Execution{
        callback_url: nil,
        job: %Prikke.Jobs.Job{callback_url: nil}
      }

      assert Callbacks.send_callback(execution) == :noop
    end
  end
end
