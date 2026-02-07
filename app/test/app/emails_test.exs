defmodule Prikke.EmailsTest do
  use Prikke.DataCase

  import Prikke.AccountsFixtures

  alias Prikke.Emails

  describe "log_email/1" do
    test "creates an email log entry" do
      {:ok, log} =
        Emails.log_email(%{
          to: "user@example.com",
          subject: "Test Subject",
          email_type: "login_instructions",
          status: "sent"
        })

      assert log.to == "user@example.com"
      assert log.subject == "Test Subject"
      assert log.email_type == "login_instructions"
      assert log.status == "sent"
      assert log.error == nil
      assert log.organization_id == nil
    end

    test "creates a failed email log with error" do
      {:ok, log} =
        Emails.log_email(%{
          to: "user@example.com",
          subject: "Test",
          email_type: "job_failure",
          status: "failed",
          error: "Connection refused"
        })

      assert log.status == "failed"
      assert log.error == "Connection refused"
    end

    test "creates an email log with organization" do
      user = user_fixture()
      {:ok, org} = Prikke.Accounts.create_organization(user, %{name: "Test Org"})

      {:ok, log} =
        Emails.log_email(%{
          to: "user@example.com",
          subject: "Job failed",
          email_type: "job_failure",
          status: "sent",
          organization_id: org.id
        })

      assert log.organization_id == org.id
    end

    test "validates required fields" do
      assert {:error, changeset} = Emails.log_email(%{})
      assert errors_on(changeset).to
      assert errors_on(changeset).subject
      assert errors_on(changeset).email_type
      assert errors_on(changeset).status
    end

    test "validates status inclusion" do
      assert {:error, changeset} =
               Emails.log_email(%{
                 to: "a@b.com",
                 subject: "x",
                 email_type: "test",
                 status: "invalid"
               })

      assert errors_on(changeset).status
    end
  end

  describe "list_recent_emails/1" do
    test "returns recent emails ordered by most recent first" do
      {:ok, old} =
        Emails.log_email(%{
          to: "old@test.com",
          subject: "Old",
          email_type: "test",
          status: "sent"
        })

      # Backdate the first email so ordering is deterministic
      Prikke.Repo.update_all(
        from(e in Prikke.Emails.EmailLog, where: e.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      {:ok, _new} =
        Emails.log_email(%{
          to: "new@test.com",
          subject: "New",
          email_type: "test",
          status: "sent"
        })

      emails = Emails.list_recent_emails(limit: 10)
      assert length(emails) == 2
      assert hd(emails).to == "new@test.com"
    end

    test "respects limit" do
      for i <- 1..5 do
        Emails.log_email(%{
          to: "user#{i}@test.com",
          subject: "Test #{i}",
          email_type: "test",
          status: "sent"
        })
      end

      assert length(Emails.list_recent_emails(limit: 3)) == 3
    end
  end

  describe "count_emails_today/0" do
    test "counts emails sent today" do
      {:ok, _} =
        Emails.log_email(%{
          to: "user@test.com",
          subject: "Today",
          email_type: "test",
          status: "sent"
        })

      assert Emails.count_emails_today() == 1
    end
  end

  describe "cleanup_old_email_logs/1" do
    test "deletes logs older than retention days" do
      # Insert a log, then manually backdate it
      {:ok, old_log} =
        Emails.log_email(%{
          to: "old@test.com",
          subject: "Old",
          email_type: "test",
          status: "sent"
        })

      # Backdate to 31 days ago
      old_date = DateTime.add(DateTime.utc_now(), -31, :day)

      Prikke.Repo.update_all(
        from(e in Prikke.Emails.EmailLog, where: e.id == ^old_log.id),
        set: [inserted_at: old_date]
      )

      {:ok, _recent} =
        Emails.log_email(%{
          to: "new@test.com",
          subject: "New",
          email_type: "test",
          status: "sent"
        })

      {deleted, _} = Emails.cleanup_old_email_logs(30)
      assert deleted == 1

      remaining = Emails.list_recent_emails()
      assert length(remaining) == 1
      assert hd(remaining).to == "new@test.com"
    end
  end
end
