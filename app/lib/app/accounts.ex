defmodule Prikke.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Prikke.Repo

  alias Prikke.Accounts.{User, UserToken, UserNotifier, Organization, Membership, ApiKey}

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
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
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
  Gets an organization by slug.
  """
  def get_organization_by_slug(slug), do: Repo.get_by(Organization, slug: slug)

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
  def update_organization(organization, attrs) do
    organization
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Upgrades an organization to Pro tier.
  """
  def upgrade_organization_to_pro(organization) do
    organization
    |> Ecto.Changeset.change(tier: "pro")
    |> Repo.update()
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
  def update_notification_settings(organization, attrs) do
    organization
    |> Organization.notification_changeset(attrs)
    |> Repo.update()
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
  def update_membership_role(membership, role) do
    membership
    |> Membership.changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Deletes a membership.
  """
  def delete_membership(membership) do
    Repo.delete(membership)
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

  ## API Keys

  @doc """
  Creates an API key for an organization.
  Returns {:ok, api_key, raw_secret} where raw_secret should be shown once to the user.
  """
  def create_api_key(organization, user, attrs \\ %{}) do
    {key_id, raw_secret} = ApiKey.generate_key_pair()
    key_hash = ApiKey.hash_secret(raw_secret)

    attrs =
      attrs
      |> Map.put(:key_id, key_id)
      |> Map.put(:key_hash, key_hash)
      |> Map.put(:organization_id, organization.id)
      |> Map.put(:created_by_id, user.id)

    case %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
      {:ok, api_key} -> {:ok, api_key, raw_secret}
      {:error, changeset} -> {:error, changeset}
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
  Verifies an API key and returns the organization if valid.
  Expected format: "pk_live_xxx.sk_live_yyy" or just the key_id for lookup.
  """
  def verify_api_key(full_key) do
    case String.split(full_key, ".") do
      [key_id, secret] ->
        case get_api_key_by_key_id(key_id) do
          nil ->
            {:error, :invalid_key}

          api_key ->
            if ApiKey.verify_secret(secret, api_key.key_hash) do
              # Update last_used_at
              api_key
              |> Ecto.Changeset.change(last_used_at: DateTime.utc_now(:second))
              |> Repo.update()

              {:ok, api_key.organization}
            else
              {:error, :invalid_secret}
            end
        end

      _ ->
        {:error, :invalid_format}
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
  def delete_api_key(api_key) do
    Repo.delete(api_key)
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
          |> OrganizationInvite.changeset(Map.merge(attrs, %{
            token: hashed_token,
            organization_id: organization.id,
            invited_by_id: invited_by.id
          }))
          |> Repo.insert()

        case result do
          {:ok, invite} -> {:ok, invite, raw_token}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, :member_limit_reached} ->
        changeset =
          %OrganizationInvite{}
          |> OrganizationInvite.changeset(attrs)
          |> Ecto.Changeset.add_error(:base, "You've reached the maximum number of team members for your plan (#{get_tier_limits(organization.tier).max_members}). Upgrade to Pro for unlimited team members.")

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
end
