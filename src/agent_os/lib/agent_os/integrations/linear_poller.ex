defmodule AgentOS.Integrations.LinearPoller do
  @moduledoc "GenServer that polls Linear for new issues tagged with agent-os"
  use GenServer
  require Logger

  @poll_interval 30_000

  def start_link(opts \\ []) do
    team_key = Keyword.get(opts, :team_key, "AOS")
    GenServer.start_link(__MODULE__, %{team_key: team_key}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    if System.get_env("LINEAR_API_KEY") do
      Logger.info(
        "LinearPoller: started, polling every #{@poll_interval}ms for team #{state.team_key}"
      )

      Process.send_after(self(), :poll, @poll_interval)
    else
      Logger.info("LinearPoller: LINEAR_API_KEY not set, polling disabled")
    end

    {:ok, Map.put(state, :processed_ids, MapSet.new())}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    Process.send_after(self(), :poll, @poll_interval)
    {:noreply, state}
  end

  defp do_poll(state) do
    case AgentOS.Integrations.Linear.list_issues(state.team_key, "Todo") do
      {:ok, issues} ->
        agent_os_issues =
          Enum.filter(issues, fn issue ->
            labels = get_in(issue, ["labels", "nodes"]) || []
            Enum.any?(labels, &(&1["name"] == "agent-os"))
          end)

        new_issues =
          Enum.reject(agent_os_issues, fn issue ->
            MapSet.member?(state.processed_ids, issue["id"])
          end)

        Enum.each(new_issues, fn issue ->
          Logger.info(
            "LinearPoller: processing issue #{issue["identifier"]}: #{issue["title"]}"
          )

          # Map to contract and log — actual pipeline execution would go here
          mapped = AgentOS.Integrations.LinearMapper.map_issue_to_contract(issue)

          Logger.info(
            "LinearPoller: mapped to contract=#{mapped.contract}, topic=#{mapped.topic}"
          )
        end)

        new_ids = new_issues |> Enum.map(& &1["id"]) |> MapSet.new()
        %{state | processed_ids: MapSet.union(state.processed_ids, new_ids)}

      {:error, reason} ->
        Logger.warning("LinearPoller: failed to fetch issues: #{inspect(reason)}")
        state
    end
  end
end
