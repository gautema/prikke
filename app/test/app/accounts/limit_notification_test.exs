defmodule Prikke.Accounts.LimitNotificationTest do
  use Prikke.DataCase, async: true

  import Prikke.AccountsFixtures

  alias Prikke.Accounts

  describe "maybe_send_limit_notification/2" do
    setup do
      user = user_fixture()
      org = organization_fixture(%{user: user})
      %{org: org, user: user}
    end

    test "updates warning timestamp at 80% of limit", %{org: org} do
      assert org.limit_warning_sent_at == nil

      # Free tier limit is 5000, so 80% = 4000
      Accounts.maybe_send_limit_notification(org, 4000)

      # Check timestamp was updated
      updated_org = Accounts.get_organization(org.id)
      assert updated_org.limit_warning_sent_at != nil
    end

    test "updates limit reached timestamp at 100%", %{org: org} do
      assert org.limit_reached_sent_at == nil

      # Free tier limit is 5000
      Accounts.maybe_send_limit_notification(org, 5000)

      # Check timestamp was updated
      updated_org = Accounts.get_organization(org.id)
      assert updated_org.limit_reached_sent_at != nil
    end

    test "does not update timestamps below 80%", %{org: org} do
      # 79% of 5000 = 3950
      Accounts.maybe_send_limit_notification(org, 3950)

      # No timestamps updated
      updated_org = Accounts.get_organization(org.id)
      assert updated_org.limit_warning_sent_at == nil
      assert updated_org.limit_reached_sent_at == nil
    end

    test "does not update warning timestamp twice in same month", %{org: org} do
      # Send first warning
      Accounts.maybe_send_limit_notification(org, 4000)
      updated_org = Accounts.get_organization(org.id)
      first_timestamp = updated_org.limit_warning_sent_at
      assert first_timestamp != nil

      # Try to send again
      Accounts.maybe_send_limit_notification(updated_org, 4100)

      # Timestamp should not change
      org_after = Accounts.get_organization(org.id)
      assert org_after.limit_warning_sent_at == first_timestamp
    end

    test "does not update limit reached timestamp twice in same month", %{org: org} do
      # Send first alert
      Accounts.maybe_send_limit_notification(org, 5000)
      updated_org = Accounts.get_organization(org.id)
      first_timestamp = updated_org.limit_reached_sent_at
      assert first_timestamp != nil

      # Try to send again
      Accounts.maybe_send_limit_notification(updated_org, 5100)

      # Timestamp should not change
      org_after = Accounts.get_organization(org.id)
      assert org_after.limit_reached_sent_at == first_timestamp
    end

    test "updates warning timestamp for pro tier at 80% of 1M limit", %{user: user} do
      # Create a pro org - pro tier has 1M limit
      org = organization_fixture(%{user: user, tier: "pro"})
      assert org.limit_warning_sent_at == nil

      # 80% of 1M = 800k
      Accounts.maybe_send_limit_notification(org, 800_000)

      # Should update warning timestamp
      updated_org = Accounts.get_organization(org.id)
      assert updated_org.limit_warning_sent_at != nil
    end

    test "skips when below warning threshold", %{org: org} do
      # 50% of 5000 = 2500
      result = Accounts.maybe_send_limit_notification(org, 2500)
      assert result == :ok

      updated_org = Accounts.get_organization(org.id)
      assert updated_org.limit_warning_sent_at == nil
      assert updated_org.limit_reached_sent_at == nil
    end
  end

  describe "sent_this_month?/2 helper" do
    test "returns false for nil" do
      # This is implicitly tested via maybe_send_limit_notification
      # A fresh org with nil timestamps should trigger notifications
      user = user_fixture()
      org = organization_fixture(%{user: user})

      Accounts.maybe_send_limit_notification(org, 4000)
      updated_org = Accounts.get_organization(org.id)
      assert updated_org.limit_warning_sent_at != nil
    end
  end
end
