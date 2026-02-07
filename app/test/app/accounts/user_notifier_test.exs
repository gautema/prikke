defmodule Prikke.Accounts.UserNotifierTest do
  use Prikke.DataCase, async: true

  import Prikke.AccountsFixtures

  alias Prikke.Accounts.UserNotifier

  describe "deliver_monthly_summary/1" do
    setup do
      # Configure admin_email for tests
      original = Application.get_env(:app, Prikke.Mailer)

      Application.put_env(
        :app,
        Prikke.Mailer,
        Keyword.put(original, :admin_email, "admin@test.com")
      )

      on_exit(fn ->
        Application.put_env(:app, Prikke.Mailer, original)
      end)

      stats = %{
        total_users: 42,
        new_users: 5,
        total_orgs: 10,
        new_orgs: 2,
        pro_orgs: 3,
        total_tasks: 100,
        enabled_tasks: 80,
        executions: %{
          total: 15_000,
          success: 14_500,
          failed: 400,
          timeout: 100
        },
        success_rate: 97,
        top_orgs: [],
        total_monitors: 25,
        down_monitors: 1,
        emails_sent: 350,
        month_name: "January 2026"
      }

      %{stats: stats}
    end

    test "sends email to admin_email", %{stats: stats} do
      assert {:ok, email} = UserNotifier.deliver_monthly_summary(stats)
      assert email.to == [{"", "admin@test.com"}]
    end

    test "subject contains month name", %{stats: stats} do
      assert {:ok, email} = UserNotifier.deliver_monthly_summary(stats)
      assert email.subject == "Monthly Summary: January 2026"
    end

    test "text body contains stats", %{stats: stats} do
      assert {:ok, email} = UserNotifier.deliver_monthly_summary(stats)
      assert email.text_body =~ "42 total"
      assert email.text_body =~ "5 new"
      assert email.text_body =~ "15,000"
      assert email.text_body =~ "97%"
    end

    test "html body contains stat cards", %{stats: stats} do
      assert {:ok, email} = UserNotifier.deliver_monthly_summary(stats)
      assert email.html_body =~ "Monthly Summary"
      assert email.html_body =~ "January 2026"
      assert email.html_body =~ "42"
      assert email.html_body =~ "15,000"
    end

    test "renders top orgs when present", %{stats: stats} do
      org = organization_fixture()

      stats = %{stats | top_orgs: [{org, 500, 5000}]}

      assert {:ok, email} = UserNotifier.deliver_monthly_summary(stats)
      assert email.html_body =~ org.name
      assert email.html_body =~ "500"
      assert email.html_body =~ "10%"
    end

    test "skips when no admin_email configured", %{stats: stats} do
      original = Application.get_env(:app, Prikke.Mailer)
      Application.put_env(:app, Prikke.Mailer, Keyword.delete(original, :admin_email))

      on_exit(fn ->
        Application.put_env(:app, Prikke.Mailer, original)
      end)

      assert {:ok, :skipped} = UserNotifier.deliver_monthly_summary(stats)
    end

    test "handles nil success rate", %{stats: stats} do
      stats = %{stats | success_rate: nil}
      assert {:ok, email} = UserNotifier.deliver_monthly_summary(stats)
      assert email.text_body =~ "N/A"
      assert email.html_body =~ "N/A"
    end
  end
end
