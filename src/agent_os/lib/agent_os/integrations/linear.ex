defmodule AgentOS.Integrations.Linear do
  @moduledoc "Elixir client for Linear GraphQL API"
  require Logger

  @api_url "https://api.linear.app/graphql"

  def list_issues(team_key, status \\ "Todo") do
    query = """
    { issues(filter: { team: { key: { eq: "#{team_key}" } }, state: { name: { eq: "#{status}" } } }, first: 50) {
      nodes { id identifier title description labels { nodes { name } } priority state { name } }
    } }
    """

    case graphql(query) do
      {:ok, %{"data" => %{"issues" => %{"nodes" => issues}}}} -> {:ok, issues}
      error -> error
    end
  end

  def get_issue(identifier) do
    query = """
    { issue(id: "#{identifier}") { id identifier title description labels { nodes { name } } state { name } } }
    """

    case graphql(query) do
      {:ok, %{"data" => %{"issue" => issue}}} -> {:ok, issue}
      error -> error
    end
  end

  def update_status(issue_id, _state_name) do
    # First find the state ID, then update
    mutation = """
    mutation { issueUpdate(id: "#{issue_id}", input: { stateId: "TODO_FIND_STATE_ID" }) { success } }
    """

    # Simplified — in practice, need to lookup state IDs first
    graphql(mutation)
  end

  def add_comment(issue_id, body) do
    escaped = String.replace(body, "\"", "\\\"")

    mutation = """
    mutation { commentCreate(input: { issueId: "#{issue_id}", body: "#{escaped}" }) { success } }
    """

    graphql(mutation)
  end

  defp graphql(query) do
    case api_key() do
      nil ->
        {:error, :no_linear_api_key}

      key ->
        body = Jason.encode!(%{query: query})
        url = String.to_charlist(@api_url)

        headers = [
          {~c"content-type", ~c"application/json"},
          {~c"authorization", ~c"#{key}"}
        ]

        :inets.start()
        :ssl.start()

        case :httpc.request(:post, {url, headers, ~c"application/json", body},
               [{:timeout, 15_000}],
               body_format: :binary
             ) do
          {:ok, {{_, 200, _}, _headers, resp_body}} -> Jason.decode(resp_body)
          {:ok, {{_, status, _}, _headers, resp_body}} -> {:error, {:api_error, status, resp_body}}
          {:error, reason} -> {:error, {:http_error, reason}}
        end
    end
  end

  defp api_key, do: System.get_env("LINEAR_API_KEY")
end
