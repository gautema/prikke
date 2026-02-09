defmodule Prikke.AccountsBillingTest do
  use Prikke.DataCase, async: true

  alias Prikke.Accounts

  import Prikke.AccountsFixtures

  describe "activate_subscription/4" do
    test "sets org to pro with creem fields and defaults to monthly" do
      org = organization_fixture()
      assert org.tier == "free"

      {:ok, updated} =
        Accounts.activate_subscription(org.id, "cus_123", "sub_456")

      assert updated.tier == "pro"
      assert updated.creem_customer_id == "cus_123"
      assert updated.creem_subscription_id == "sub_456"
      assert updated.subscription_status == "active"
      assert updated.billing_period == "monthly"
    end

    test "sets billing_period to yearly when specified" do
      org = organization_fixture()

      {:ok, updated} =
        Accounts.activate_subscription(org.id, "cus_123", "sub_456", billing_period: "yearly")

      assert updated.tier == "pro"
      assert updated.billing_period == "yearly"
    end

    test "sets billing_period to monthly when specified" do
      org = organization_fixture()

      {:ok, updated} =
        Accounts.activate_subscription(org.id, "cus_123", "sub_456", billing_period: "monthly")

      assert updated.billing_period == "monthly"
    end

    test "stores current_period_end when provided" do
      org = organization_fixture()
      period_end = ~U[2026-03-12 11:58:38Z]

      {:ok, updated} =
        Accounts.activate_subscription(org.id, "cus_123", "sub_456",
          billing_period: "monthly",
          current_period_end: period_end
        )

      assert updated.current_period_end == period_end
    end

    test "returns error for non-existent org" do
      assert {:error, :not_found} =
               Accounts.activate_subscription(Ecto.UUID.generate(), "cus_123", "sub_456")
    end

    test "is idempotent - can be called twice" do
      org = organization_fixture()

      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_456")
      {:ok, updated} = Accounts.activate_subscription(org.id, "cus_123", "sub_456")

      assert updated.tier == "pro"
      assert updated.subscription_status == "active"
    end
  end

  describe "update_subscription_status/2" do
    test "keeps pro for active status" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_789")

      {:ok, updated} = Accounts.update_subscription_status("sub_789", "active")
      assert updated.tier == "pro"
      assert updated.subscription_status == "active"
    end

    test "keeps pro for past_due status" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_789")

      {:ok, updated} = Accounts.update_subscription_status("sub_789", "past_due")
      assert updated.tier == "pro"
      assert updated.subscription_status == "past_due"
    end

    test "keeps pro for scheduled_cancel status" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_789")

      {:ok, updated} = Accounts.update_subscription_status("sub_789", "scheduled_cancel")
      assert updated.tier == "pro"
      assert updated.subscription_status == "scheduled_cancel"
    end

    test "keeps pro for paused status" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_789")

      {:ok, updated} = Accounts.update_subscription_status("sub_789", "paused")
      assert updated.tier == "pro"
      assert updated.subscription_status == "paused"
    end

    test "downgrades to free for canceled status" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_789")

      {:ok, updated} = Accounts.update_subscription_status("sub_789", "canceled")
      assert updated.tier == "free"
      assert updated.subscription_status == "canceled"
    end

    test "downgrades to free for expired status" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_789")

      {:ok, updated} = Accounts.update_subscription_status("sub_789", "expired")
      assert updated.tier == "free"
      assert updated.subscription_status == "expired"
    end

    test "updates current_period_end when provided" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_789")
      period_end = ~U[2026-04-12 11:58:38Z]

      {:ok, updated} =
        Accounts.update_subscription_status("sub_789", "active", current_period_end: period_end)

      assert updated.current_period_end == period_end
    end

    test "returns error for unknown subscription" do
      assert {:error, :not_found} =
               Accounts.update_subscription_status("sub_nonexistent", "active")
    end
  end

  describe "get_organization_by_subscription/1" do
    test "finds org by subscription id" do
      org = organization_fixture()
      {:ok, _} = Accounts.activate_subscription(org.id, "cus_123", "sub_lookup")

      found = Accounts.get_organization_by_subscription("sub_lookup")
      assert found.id == org.id
    end

    test "returns nil for unknown subscription" do
      assert nil == Accounts.get_organization_by_subscription("sub_nonexistent")
    end
  end
end
