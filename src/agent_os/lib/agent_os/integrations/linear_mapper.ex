defmodule AgentOS.Integrations.LinearMapper do
  @moduledoc "Maps Linear issues to agent-os contract specifications"

  @label_to_contract %{
    "research" => "research-report",
    "dashboard" => "market-dashboard"
  }

  def map_issue_to_contract(issue) do
    labels = get_in(issue, ["labels", "nodes"]) || []
    label_names = labels |> Enum.map(& &1["name"]) |> Enum.map(&String.downcase/1)

    contract =
      Enum.find_value(label_names, fn label ->
        Map.get(@label_to_contract, label)
      end) || "research-report"

    topic = issue["title"] || "research"

    %{contract: contract, topic: topic, issue_id: issue["id"], identifier: issue["identifier"]}
  end
end
