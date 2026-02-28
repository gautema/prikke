defmodule Prikke.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Accounts.{User, UserToken, UserNotifier, Organization, Membership, ApiKey}
  alias Prikke.Audit

  # Tier limits for organizations
  @tier_limits %{
    "free" => %{max_members: 2},
    "pro" => %{max_members: :unlimited}
  }

  def tier_limits, do: @tier_limits

  def get_tier_limits(tier) do
    Map.get(@tier_limits, tier, @tier_limits["free"])
  end

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    result =
      %User{}
      |> User.email_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, user} ->
        # Send admin notification asynchronously
        Task.start(fn -> UserNotifier.deliver_admin_new_user_notification(user) end)
        {:ok, user}

      error ->
        error
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Prikke.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Prikke.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  ## Organizations

  @doc """
  Creates an organization and adds the given user as owner.
  """
  def create_organization(user, attrs) do
    Repo.transaction(fn ->
      changeset = Organization.changeset(%Organization{}, attrs)

      case Repo.insert(changeset) do
        {:ok, org} ->
          case create_membership(org, user, "owner") do
            {:ok, _membership} -> org
            {:error, _} -> Repo.rollback(changeset)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Gets a single organization.
  """
  def get_organization(id), do: Repo.get(Organization, id)

  @doc """
  Gets an organization by ID, but only if the user is a member.
  Returns nil if the organization doesn't exist or the user isn't a member.
  """
  def get_organization_for_user(%User{} = user, org_id) when is_binary(org_id) do
    from(o in Organization,
      join: m in Membership,
      on: m.organization_id == o.id,
      where: o.id == ^org_id and m.user_id == ^user.id
    )
    |> Repo.one()
  end

  def get_organization_for_user(_user, _org_id), do: nil

  @doc """
  Lists all organizations for a user.
  """
  def list_user_organizations(user) do
    from(o in Organization,
      join: m in Membership,
      on: m.organization_id == o.id,
      where: m.user_id == ^user.id,
      order_by: [asc: o.name]
    )
    |> Repo.all()
  end

  @doc """
  Lists all organizations. Used for system-wide cleanup tasks.
  """
  def list_all_organizations do
    Repo.all(Organization)
  end

  @doc """
  Updates an organization.
  """
  def update_organization(organization, attrs, opts \\ []) do
    old_org = Map.from_struct(organization)

    case organization
         |> Organization.changeset(attrs)
         |> Repo.update() do
      {:ok, updated_org} ->
        changes = Audit.compute_changes(old_org, Map.from_struct(updated_org), [:name])
        audit_log(opts, :updated, :organization, updated_org.id, updated_org.id, changes: changes)
        {:ok, updated_org}

      error ->
        error
    end
  end

  @doc """
  Upgrades an organization to Pro tier.
  """
  def upgrade_organization_to_pro(organization, opts \\ []) do
    result =
      organization
      |> Ecto.Changeset.change(tier: "pro")
      |> Repo.update()

    case result do
      {:ok, org} ->
        # Send admin notification asynchronously
        Task.start(fn -> UserNotifier.deliver_admin_upgrade_notification(org) end)
        audit_log(opts, :upgraded, :organization, org.id, org.id)
        {:ok, org}

      error ->
        error
    end
  end

  @doc """
  Regenerates the webhook secret for an organization.
  Returns the new secret (only time it's available in plaintext).
  """
  def regenerate_webhook_secret(organization, opts \\ []) do
    new_secret = Organization.generate_webhook_secret()

    case organization
         |> Ecto.Changeset.change(webhook_secret: new_secret)
         |> Repo.update() do
      {:ok, updated_org} ->
        audit_log(
          opts,
          :regenerated_webhook_secret,
          :organization,
          updated_org.id,
          updated_org.id
        )

        {:ok, updated_org}

      error ->
        error
    end
  end

  @doc """
  Deletes an organization.
  """
  def delete_organization(organization) do
    Repo.delete(organization)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking organization changes.
  """
  def change_organization(organization, attrs \\ %{}) do
    Organization.changeset(organization, attrs)
  end

  @doc """
  Updates notification settings for an organization.
  """
  def update_notification_settings(organization, attrs, opts \\ []) do
    old_org = Map.from_struct(organization)

    case organization
         |> Organization.notification_changeset(attrs)
         |> Repo.update() do
      {:ok, updated_org} ->
        changes =
          Audit.compute_changes(old_org, Map.from_struct(updated_org), [
            :notify_on_failure,
            :notify_on_recovery,
            :notification_email,
            :notification_webhook_url
          ])

        audit_log(opts, :updated, :organization, updated_org.id, updated_org.id, changes: changes)
        {:ok, updated_org}

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking notification settings changes.
  """
  def change_notification_settings(organization, attrs \\ %{}) do
    Organization.notification_changeset(organization, attrs)
  end

  ## Memberships

  @doc """
  Creates a membership.
  """
  def create_membership(organization, user, role \\ "member") do
    %Membership{}
    |> Membership.changeset(%{organization_id: organization.id, user_id: user.id, role: role})
    |> Repo.insert()
  end

  @doc """
  Gets a user's membership in an organization.
  """
  def get_membership(organization, user) do
    Repo.get_by(Membership, organization_id: organization.id, user_id: user.id)
  end

  @doc """
  Gets a membership by ID.
  """
  def get_membership_by_id(id) do
    Repo.get(Membership, id)
  end

  @doc """
  Lists all members of an organization.
  """
  def list_organization_members(organization) do
    from(m in Membership,
      where: m.organization_id == ^organization.id,
      preload: [:user],
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Counts members in an organization.
  """
  def count_organization_members(organization) do
    from(m in Membership, where: m.organization_id == ^organization.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts pending invites for an organization.
  """
  def count_pending_invites(organization) do
    from(i in Prikke.Accounts.OrganizationInvite,
      where: i.organization_id == ^organization.id and is_nil(i.accepted_at)
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Updates a membership role.
  """
  def update_membership_role(membership, role, opts \\ []) do
    old_role = membership.role
    membership = Repo.preload(membership, :user)

    case membership
         |> Membership.changeset(%{role: role})
         |> Repo.update() do
      {:ok, updated} ->
        changes = %{
          "role" => %{"from" => old_role, "to" => role},
          "user_email" => membership.user.email
        }

        audit_log(opts, :role_changed, :membership, updated.id, membership.organization_id,
          changes: changes
        )

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Deletes a membership.
  """
  def delete_membership(membership, opts \\ []) do
    membership = Repo.preload(membership, :user)

    case Repo.delete(membership) do
      {:ok, deleted} ->
        audit_log(opts, :removed, :membership, deleted.id, membership.organization_id,
          changes: %{"user_email" => membership.user.email}
        )

        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Checks if user has at least the given role in the organization.
  """
  def has_role?(organization, user, required_role) do
    case get_membership(organization, user) do
      nil -> false
      membership -> role_level(membership.role) >= role_level(required_role)
    end
  end

  defp role_level("owner"), do: 3
  defp role_level("admin"), do: 2
  defp role_level("member"), do: 1
  defp role_level(_), do: 0

  @doc """
  Gets the owner's email for an organization.
  Returns nil if no owner is found.
  """
  def get_organization_owner_email(organization) do
    from(m in Membership,
      join: u in User,
      on: u.id == m.user_id,
      where: m.organization_id == ^organization.id and m.role == "owner",
      select: u.email,
      limit: 1
    )
    |> Repo.one()
  end

  ## Billing

  @doc """
  Creates a Creem checkout session for upgrading an organization.
  Returns `{:ok, checkout_url}` or `{:error, reason}`.
  """
  def create_checkout_session(organization, user_email, success_url, billing_period \\ "monthly") do
    Prikke.Billing.Creem.create_checkout(organization.id, user_email, success_url, billing_period)
  end

  @doc """
  Activates a subscription after checkout completion.
  Sets the organization to pro tier and stores Creem IDs.
  """
  def activate_subscription(org_id, customer_id, subscription_id, opts \\ []) do
    billing_period = Keyword.get(opts, :billing_period, "monthly")
    current_period_end = Keyword.get(opts, :current_period_end)

    case get_organization(org_id) do
      nil ->
        {:error, :not_found}

      org ->
        changes =
          %{
            tier: "pro",
            creem_customer_id: customer_id,
            creem_subscription_id: subscription_id,
            subscription_status: "active",
            billing_period: billing_period
          }
          |> maybe_put(:current_period_end, current_period_end)

        org
        |> Ecto.Changeset.change(changes)
        |> Repo.update()
    end
  end

  @doc """
  Updates subscription status based on Creem webhook events.
  Keeps pro tier for active/past_due/scheduled_cancel/paused.
  Downgrades to free for canceled/expired.
  """
  def update_subscription_status(subscription_id, status, opts \\ []) do
    current_period_end = Keyword.get(opts, :current_period_end)

    case get_organization_by_subscription(subscription_id) do
      nil ->
        {:error, :not_found}

      org ->
        tier = subscription_status_to_tier(status)

        changes =
          %{subscription_status: status, tier: tier}
          |> maybe_put(:current_period_end, current_period_end)

        org
        |> Ecto.Changeset.change(changes)
        |> Repo.update()
    end
  end

  @doc """
  Looks up an organization by its Creem subscription ID.
  """
  def get_organization_by_subscription(subscription_id) do
    Repo.get_by(Organization, creem_subscription_id: subscription_id)
  end

  @doc """
  Cancels a subscription via the Creem API (scheduled at end of period).
  """
  def cancel_subscription(organization) do
    case Prikke.Billing.Creem.cancel_subscription(organization.creem_subscription_id) do
      {:ok, _response} ->
        organization
        |> Ecto.Changeset.change(subscription_status: "scheduled_cancel")
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Switches a monthly Pro subscription to yearly via the Creem upgrade API.
  """
  def switch_to_yearly(organization) do
    yearly_product_id = Application.get_env(:app, Prikke.Billing.Creem)[:yearly_product_id]

    case Prikke.Billing.Creem.upgrade_subscription(
           organization.creem_subscription_id,
           yearly_product_id
         ) do
      {:ok, _response} ->
        organization
        |> Ecto.Changeset.change(billing_period: "yearly")
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the Creem billing portal URL for an organization.
  """
  def get_billing_portal_url(organization) do
    Prikke.Billing.Creem.get_billing_portal_url(organization.creem_customer_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp subscription_status_to_tier(status)
       when status in ["active", "past_due", "scheduled_cancel", "paused"],
       do: "pro"

  defp subscription_status_to_tier(_status), do: "free"

  ## Limit Notifications

  @doc """
  Checks if the organization has crossed a limit threshold and sends notification if needed.
  Called by the scheduler after creating executions.

  Thresholds:
  - 80%: Warning notification
  - 100%: Limit reached notification

  Only sends one notification per threshold per month.
  """
  def maybe_send_limit_notification(organization, current_count) do
    tier_limits = Prikke.Tasks.get_tier_limits(organization.tier)
    limit = tier_limits.max_monthly_executions

    # Skip if unlimited
    if limit == :unlimited do
      :ok
    else
      percent = current_count / limit * 100
      now = DateTime.utc_now()

      cond do
        # At or over 100% - send limit reached notification
        percent >= 100 and not sent_this_month?(organization.limit_reached_sent_at, now) ->
          send_limit_reached_notification(organization, limit, now)

        # At or over 80% but under 100% - send warning notification
        percent >= 80 and not sent_this_month?(organization.limit_warning_sent_at, now) ->
          send_limit_warning_notification(organization, current_count, limit, now)

        true ->
          :ok
      end
    end
  end

  defp sent_this_month?(nil, _now), do: false

  defp sent_this_month?(sent_at, now) do
    sent_at.year == now.year and sent_at.month == now.month
  end

  defp send_limit_warning_notification(organization, current, limit, now) do
    email = get_notification_email(organization)

    if email do
      Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
        UserNotifier.deliver_limit_warning(email, organization, current, limit)
      end)
    end

    # Update the sent_at timestamp (truncate to second for utc_datetime field)
    organization
    |> Ecto.Changeset.change(limit_warning_sent_at: DateTime.truncate(now, :second))
    |> Repo.update()

    :ok
  end

  defp send_limit_reached_notification(organization, limit, now) do
    email = get_notification_email(organization)

    if email do
      Task.Supervisor.start_child(Prikke.TaskSupervisor, fn ->
        UserNotifier.deliver_limit_reached(email, organization, limit)
      end)
    end

    # Update the sent_at timestamp (truncate to second for utc_datetime field)
    organization
    |> Ecto.Changeset.change(limit_reached_sent_at: DateTime.truncate(now, :second))
    |> Repo.update()

    :ok
  end

  defp get_notification_email(organization) do
    # Prefer org notification email, fall back to owner email
    organization.notification_email || get_organization_owner_email(organization)
  end

  ## API Keys

  @doc """
  Creates an API key for an organization.
  Returns {:ok, api_key, raw_secret} where raw_secret should be shown once to the user.
  """
  def create_api_key(organization, user, attrs \\ %{}, opts \\ []) do
    {key_id, raw_secret} = ApiKey.generate_key_pair()
    key_hash = ApiKey.hash_secret(raw_secret)

    attrs =
      attrs
      |> Map.put(:key_id, key_id)
      |> Map.put(:key_hash, key_hash)
      |> Map.put(:organization_id, organization.id)
      |> Map.put(:created_by_id, user.id)

    case %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
      {:ok, api_key} ->
        audit_log(opts, :api_key_created, :api_key, api_key.id, organization.id,
          changes: %{"name" => api_key.name, "key_id" => key_id}
        )

        {:ok, api_key, raw_secret}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets an API key by key_id (the public identifier).
  """
  def get_api_key_by_key_id(key_id) do
    Repo.get_by(ApiKey, key_id: key_id)
    |> Repo.preload(:organization)
  end

  @doc """
  Verifies an API key and returns the organization and key name if valid.
  Expected format: "pk_live_xxx.sk_live_yyy" or just the key_id for lookup.
  Returns {:ok, organization, api_key_name} on success.
  """
  def verify_api_key(full_key) do
    case String.split(full_key, ".") do
      [key_id, secret] ->
        case Prikke.ApiKeyCache.lookup(key_id) do
          {:ok, key_hash, organization, api_key_name} ->
            # Cache hit — verify secret against cached hash
            if ApiKey.verify_secret(secret, key_hash) do
              debounce_last_used_at(key_id)
              {:ok, organization, api_key_name}
            else
              {:error, :invalid_secret}
            end

          :miss ->
            # Cache miss — fetch from DB, cache result
            case get_api_key_by_key_id(key_id) do
              nil ->
                {:error, :invalid_key}

              api_key ->
                api_key_name = api_key.name || api_key.key_id

                Prikke.ApiKeyCache.put(
                  key_id,
                  api_key.key_hash,
                  api_key.organization,
                  api_key_name
                )

                if ApiKey.verify_secret(secret, api_key.key_hash) do
                  debounce_last_used_at(key_id)
                  {:ok, api_key.organization, api_key_name}
                else
                  {:error, :invalid_secret}
                end
            end
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp debounce_last_used_at(key_id) do
    # Update last_used_at (debounced: only write if stale by 5+ minutes)
    now = DateTime.utc_now(:second)

    case Repo.get_by(ApiKey, key_id: key_id) do
      nil ->
        :ok

      api_key ->
        if is_nil(api_key.last_used_at) or DateTime.diff(now, api_key.last_used_at) > 300 do
          api_key
          |> Ecto.Changeset.change(last_used_at: now)
          |> Repo.update()
        end
    end
  end

  @doc """
  Lists all API keys for an organization.
  """
  def list_organization_api_keys(organization) do
    from(a in ApiKey,
      where: a.organization_id == ^organization.id,
      order_by: [desc: a.inserted_at],
      preload: [:created_by]
    )
    |> Repo.all()
  end

  @doc """
  Gets an API key by ID for an organization.
  """
  def get_api_key(organization, id) do
    from(a in ApiKey,
      where: a.id == ^id and a.organization_id == ^organization.id
    )
    |> Repo.one()
  end

  @doc """
  Deletes an API key.
  """
  def delete_api_key(api_key, opts \\ []) do
    case Repo.delete(api_key) do
      {:ok, deleted} ->
        Prikke.ApiKeyCache.invalidate(deleted.key_id)

        audit_log(opts, :api_key_deleted, :api_key, deleted.id, deleted.organization_id,
          changes: %{"name" => deleted.name, "key_id" => deleted.key_id}
        )

        {:ok, deleted}

      error ->
        error
    end
  end

  ## Organization Invites

  alias Prikke.Accounts.OrganizationInvite

  @doc """
  Creates an invite for an organization.
  Returns {:ok, invite, token} on success where token is the raw token to send in email.

  Enforces tier limits:
  - Free: max 2 members (including pending invites)
  - Pro: unlimited members
  """
  def create_organization_invite(organization, invited_by, attrs) do
    organization = Repo.preload(organization, [])

    case check_member_limit(organization) do
      :ok ->
        {raw_token, hashed_token} = OrganizationInvite.build_token()

        result =
          %OrganizationInvite{}
          |> OrganizationInvite.changeset(
            Map.merge(attrs, %{
              token: hashed_token,
              organization_id: organization.id,
              invited_by_id: invited_by.id
            })
          )
          |> Repo.insert()

        case result do
          {:ok, invite} -> {:ok, invite, raw_token}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, :member_limit_reached} ->
        changeset =
          %OrganizationInvite{}
          |> OrganizationInvite.changeset(attrs)
          |> Ecto.Changeset.add_error(
            :base,
            "You've reached the maximum number of team members for your plan (#{get_tier_limits(organization.tier).max_members}). Upgrade to Pro for unlimited team members."
          )

        {:error, changeset}
    end
  end

  defp check_member_limit(%Organization{tier: tier} = org) do
    limits = get_tier_limits(tier)

    case limits.max_members do
      :unlimited ->
        :ok

      max when is_integer(max) ->
        current_count = count_organization_members(org) + count_pending_invites(org)
        if current_count < max, do: :ok, else: {:error, :member_limit_reached}
    end
  end

  @doc """
  Gets an invite by its token.
  """
  def get_invite_by_token(token) do
    case OrganizationInvite.hash_token(token) do
      {:ok, hashed_token} ->
        from(i in OrganizationInvite,
          where: i.token == ^hashed_token and is_nil(i.accepted_at),
          preload: [:organization]
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  Accepts an invite and creates a membership for the user.
  """
  def accept_invite(invite, user) do
    Repo.transaction(fn ->
      # Check if user is already a member
      if get_membership(invite.organization, user) do
        Repo.rollback(:already_member)
      end

      # Create membership
      case create_membership(invite.organization, user, invite.role) do
        {:ok, membership} ->
          # Mark invite as accepted
          invite
          |> OrganizationInvite.accept_changeset()
          |> Repo.update!()

          membership

        {:error, _} ->
          Repo.rollback(:membership_failed)
      end
    end)
  end

  @doc """
  Lists pending invites for an organization.
  """
  def list_organization_invites(organization) do
    from(i in OrganizationInvite,
      where: i.organization_id == ^organization.id and is_nil(i.accepted_at),
      order_by: [desc: i.inserted_at],
      preload: [:invited_by]
    )
    |> Repo.all()
  end

  @doc """
  Lists pending invites for a user by their email.
  """
  def list_pending_invites_for_email(email) do
    from(i in OrganizationInvite,
      where: i.email == ^email and is_nil(i.accepted_at),
      order_by: [desc: i.inserted_at],
      preload: [:organization, :invited_by]
    )
    |> Repo.all()
  end

  @doc """
  Deletes a pending invite.
  """
  def delete_invite(invite) do
    Repo.delete(invite)
  end

  @doc """
  Delivers an organization invite email.
  """
  def deliver_organization_invite(invite, raw_token, url_fn) do
    invite = Repo.preload(invite, [:organization, :invited_by])

    UserNotifier.deliver_organization_invite(
      invite.email,
      invite.organization.name,
      invite.invited_by && invite.invited_by.email,
      url_fn.(raw_token)
    )
  end

  ## Superadmin Stats

  @doc """
  Counts total users.
  """
  def count_users do
    Repo.aggregate(User, :count)
  end

  @doc """
  Counts users created since a given datetime.
  """
  def count_users_since(since) do
    from(u in User, where: u.inserted_at >= ^since)
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts total organizations.
  """
  def count_organizations do
    Repo.aggregate(Organization, :count)
  end

  @doc """
  Returns the count of organizations created since the given datetime.
  """
  def count_organizations_since(since) do
    from(o in Organization, where: o.inserted_at >= ^since)
    |> Repo.aggregate(:count)
  end

  @doc """
  Lists recent user signups.
  """
  def list_recent_users(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(u in User,
      order_by: [desc: u.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Lists organizations with the most executions this month.
  Returns a list of {organization, execution_count} tuples.
  """
  def list_active_organizations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(o in Organization,
      where: o.monthly_execution_count > 0,
      order_by: [desc: o.monthly_execution_count],
      select: {o, o.monthly_execution_count},
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Lists Pro tier organizations with owner email.
  Returns a list of maps with organization name, owner email, and upgrade date.
  """
  def list_pro_organizations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(o in Organization,
      join: m in Membership,
      on: m.organization_id == o.id and m.role == "owner",
      join: u in User,
      on: u.id == m.user_id,
      where: o.tier == "pro",
      order_by: [desc: o.updated_at],
      select: %{
        id: o.id,
        name: o.name,
        owner_email: u.email,
        upgraded_at: o.updated_at
      },
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Counts Pro tier organizations.
  """
  def count_pro_organizations do
    from(o in Organization, where: o.tier == "pro")
    |> Repo.aggregate(:count)
  end

  ## Private: Audit Logging

  defp audit_log(opts, action, resource_type, resource_id, org_id, extra_opts \\ []) do
    scope = Keyword.get(opts, :scope)
    changes = Keyword.get(extra_opts, :changes, %{})

    if scope != nil do
      Audit.log(scope, action, resource_type, resource_id,
        organization_id: org_id,
        changes: changes
      )
    else
      :ok
    end
  end
end
