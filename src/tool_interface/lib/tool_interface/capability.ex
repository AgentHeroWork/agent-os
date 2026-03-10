defmodule ToolInterface.Capability do
  @moduledoc """
  Capability token system for tool access control.

  Implements capability-based security where each agent holds unforgeable tokens
  that grant specific permissions on specific tools. Tokens are scoped, time-bounded,
  rate-limited, and cryptographically signed.

  ## Capability Model

  A capability token is the runtime concretisation of the representable functor
  `Hom(T, -)` from the tool category: it encodes exactly which tool morphisms
  the bearer is authorised to invoke.

  ## Token Structure

  Each token contains:
  - `agent_id` — the agent this token is issued to
  - `tool_id` — the specific tool this token grants access to
  - `permissions` — list of permitted operations (`:invoke`, `:inspect`, `:compose`)
  - `rate_limit` — maximum invocations per minute
  - `expires_at` — UTC datetime after which the token is invalid
  - `signature` — HMAC-SHA256 signature for tamper detection

  ## Examples

      iex> {:ok, token} = ToolInterface.Capability.create("agent-1", "web-search", [:invoke], 60, 3600)
      iex> ToolInterface.Capability.authorize(token, "web-search")
      {:ok, token}

      iex> ToolInterface.Capability.authorize(token, "code-exec")
      {:error, :unauthorized}
  """

  @type permission :: :invoke | :inspect | :compose

  @type t :: %__MODULE__{
          agent_id: String.t(),
          tool_id: String.t(),
          permissions: [permission()],
          rate_limit: pos_integer(),
          expires_at: DateTime.t(),
          signature: binary(),
          invocation_count: non_neg_integer(),
          last_reset_at: DateTime.t()
        }

  @enforce_keys [:agent_id, :tool_id, :permissions, :rate_limit, :expires_at, :signature]
  defstruct [
    :agent_id,
    :tool_id,
    :permissions,
    :rate_limit,
    :expires_at,
    :signature,
    invocation_count: 0,
    last_reset_at: nil
  ]

  # Signing key — in production, this would come from a secrets manager.
  @signing_key "tool_interface_capability_signing_key_v1"

  @doc """
  Creates a new capability token for the given agent and tool.

  ## Parameters

  - `agent_id` — identifier of the agent receiving the capability
  - `tool_id` — identifier of the tool being granted
  - `permissions` — list of permissions (`:invoke`, `:inspect`, `:compose`)
  - `rate_limit` — maximum invocations per minute
  - `ttl_seconds` — time-to-live in seconds from now

  ## Returns

  `{:ok, token}` on success, `{:error, reason}` if parameters are invalid.
  """
  @spec create(String.t(), String.t(), [permission()], pos_integer(), pos_integer()) ::
          {:ok, t()} | {:error, term()}
  def create(agent_id, tool_id, permissions, rate_limit, ttl_seconds)
      when is_binary(agent_id) and is_binary(tool_id) and is_list(permissions) and
             is_integer(rate_limit) and rate_limit > 0 and
             is_integer(ttl_seconds) and ttl_seconds > 0 do
    valid_permissions = [:invoke, :inspect, :compose]

    if Enum.all?(permissions, &(&1 in valid_permissions)) do
      expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)

      token = %__MODULE__{
        agent_id: agent_id,
        tool_id: tool_id,
        permissions: permissions,
        rate_limit: rate_limit,
        expires_at: expires_at,
        signature: <<>>,
        invocation_count: 0,
        last_reset_at: DateTime.utc_now()
      }

      signature = compute_signature(token)
      {:ok, %{token | signature: signature}}
    else
      {:error, :invalid_permissions}
    end
  end

  def create(_, _, _, _, _), do: {:error, :invalid_parameters}

  @doc """
  Authorises a capability token for a specific tool invocation.

  Checks that:
  1. The token's tool_id matches the requested tool
  2. The token has not expired
  3. The token's signature is valid (tamper detection)
  4. The `:invoke` permission is present
  5. The rate limit has not been exceeded

  ## Returns

  `{:ok, updated_token}` with incremented invocation count on success,
  `{:error, reason}` on failure.
  """
  @spec authorize(t(), String.t()) ::
          {:ok, t()} | {:error, :unauthorized | :expired | :rate_limited | :invalid_signature}
  def authorize(%__MODULE__{} = token, tool_id) do
    cond do
      token.tool_id != tool_id ->
        {:error, :unauthorized}

      :invoke not in token.permissions ->
        {:error, :unauthorized}

      expired?(token) ->
        {:error, :expired}

      not valid_signature?(token) ->
        {:error, :invalid_signature}

      rate_limited?(token) ->
        {:error, :rate_limited}

      true ->
        updated = increment_invocation(token)
        {:ok, updated}
    end
  end

  def authorize(_, _), do: {:error, :unauthorized}

  @doc """
  Checks whether a token has a specific permission without consuming a rate limit slot.
  """
  @spec has_permission?(t(), permission()) :: boolean()
  def has_permission?(%__MODULE__{} = token, permission) do
    permission in token.permissions and
      not expired?(token) and
      valid_signature?(token)
  end

  @doc """
  Revokes a token by returning a token with an already-passed expiry.
  Since tokens are value types (not stored centrally), revocation is cooperative.
  """
  @spec revoke(t()) :: t()
  def revoke(%__MODULE__{} = token) do
    expired_token = %{token | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    signature = compute_signature(expired_token)
    %{expired_token | signature: signature}
  end

  @doc """
  Returns remaining invocations before the rate limit resets.
  """
  @spec remaining_invocations(t()) :: non_neg_integer()
  def remaining_invocations(%__MODULE__{} = token) do
    if should_reset_rate_window?(token) do
      token.rate_limit
    else
      max(0, token.rate_limit - token.invocation_count)
    end
  end

  # ---------- Private ----------

  defp expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp valid_signature?(%__MODULE__{} = token) do
    expected = compute_signature(%{token | signature: <<>>})
    # Constant-time comparison to prevent timing attacks
    :crypto.hash_equals(expected, token.signature)
  rescue
    _ -> false
  end

  defp rate_limited?(%__MODULE__{} = token) do
    if should_reset_rate_window?(token) do
      false
    else
      token.invocation_count >= token.rate_limit
    end
  end

  defp should_reset_rate_window?(%__MODULE__{last_reset_at: nil}), do: true

  defp should_reset_rate_window?(%__MODULE__{last_reset_at: last_reset}) do
    diff = DateTime.diff(DateTime.utc_now(), last_reset, :second)
    diff >= 60
  end

  defp increment_invocation(%__MODULE__{} = token) do
    if should_reset_rate_window?(token) do
      %{token | invocation_count: 1, last_reset_at: DateTime.utc_now()}
    else
      %{token | invocation_count: token.invocation_count + 1}
    end
  end

  defp compute_signature(%__MODULE__{} = token) do
    payload =
      "#{token.agent_id}:#{token.tool_id}:#{inspect(token.permissions)}:" <>
        "#{token.rate_limit}:#{DateTime.to_iso8601(token.expires_at)}"

    :crypto.mac(:hmac, :sha256, @signing_key, payload)
  end
end
