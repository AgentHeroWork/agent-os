defmodule AgentOS.Secrets.EnvBackend do
  @behaviour AgentOS.Secrets
  require Logger

  @credential_map %{
    github_token: {"GH_TOKEN", &__MODULE__.resolve_github_token/0},
    vercel_token: {"VERCEL_TOKEN", nil},
    openai_api_key: {"OPENAI_API_KEY", nil},
    anthropic_api_key: {"ANTHROPIC_API_KEY", nil},
    linear_api_key: {"LINEAR_API_KEY", nil},
    slack_bot_token: {"SLACK_BOT_TOKEN", nil},
    telegram_bot_token: {"TELEGRAM_BOT_TOKEN", nil}
  }

  @impl true
  def available?, do: true

  @impl true
  def resolve(credential) do
    case Map.get(@credential_map, credential) do
      nil -> {:error, {:unknown_credential, credential}}
      {env_var, resolver} ->
        case System.get_env(env_var) do
          nil when is_function(resolver) ->
            case resolver.() do
              {:ok, val} -> {:ok, val}
              _ -> {:error, {:not_found, credential}}
            end
          nil -> {:error, {:not_found, credential}}
          val -> {:ok, val}
        end
    end
  end

  def resolve_github_token do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} -> {:ok, String.trim(token)}
      _ -> {:error, :gh_auth_not_available}
    end
  rescue
    _ -> {:error, :gh_not_installed}
  end
end
