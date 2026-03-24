defmodule AgentOS.Secrets.GitHubApp do
  @moduledoc """
  GitHub App installation token generation for short-lived credentials.

  When configured (GITHUB_APP_ID + GITHUB_APP_PRIVATE_KEY), generates
  1-hour installation tokens scoped to specific repos/orgs.

  Setup:
  1. Create a GitHub App at https://github.com/settings/apps
  2. Install on AgentHeroWork org
  3. Set GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY_PATH env vars
  4. Agent-OS will generate short-lived tokens per pipeline run

  TODO: Implement JWT generation and installation token creation
  """

  def available? do
    System.get_env("GITHUB_APP_ID") != nil and
    System.get_env("GITHUB_APP_PRIVATE_KEY_PATH") != nil
  end

  def create_installation_token do
    # TODO: Implement
    # 1. Read private key from GITHUB_APP_PRIVATE_KEY_PATH
    # 2. Generate JWT with app_id
    # 3. POST /app/installations/:id/access_tokens
    # 4. Return short-lived token
    {:error, :not_implemented}
  end
end
