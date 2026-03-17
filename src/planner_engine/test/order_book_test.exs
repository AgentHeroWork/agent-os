defmodule PlannerEngine.OrderBookTest do
  use ExUnit.Case, async: false

  alias PlannerEngine.OrderBook

  setup do
    # OrderBook may already be running from the application startup
    case start_supervised(OrderBook) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "proposal submission" do
    test "submits a proposal" do
      task_id = "task_submit_#{:erlang.unique_integer([:positive])}"

      proposal = %{
        agent_id: "agent_1",
        task_id: task_id,
        execution_plan: "Run research",
        estimated_credits: 100,
        estimated_duration: 60,
        confidence_score: 0.9
      }

      assert :ok = OrderBook.submit_proposal(proposal)

      proposals = OrderBook.proposals_for_task(task_id)
      assert length(proposals) == 1
      assert hd(proposals).agent_id == "agent_1"
    end
  end

  describe "demand posting" do
    test "posts a demand" do
      task_id = "task_demand_#{:erlang.unique_integer([:positive])}"

      demand = %{
        client_id: "client_1",
        task_id: task_id,
        required_capabilities: [:web_search],
        budget_ceiling: 500
      }

      assert :ok = OrderBook.post_demand(demand)

      demands = OrderBook.demands_for_task(task_id)
      assert length(demands) == 1
      assert hd(demands).client_id == "client_1"
    end
  end

  describe "matching" do
    test "immediate match when proposal meets demand" do
      # Post demand first
      demand = %{
        client_id: "client_1",
        task_id: "task_match",
        required_capabilities: [],
        budget_ceiling: 500
      }

      OrderBook.post_demand(demand)

      # Submit proposal within budget
      proposal = %{
        agent_id: "agent_1",
        task_id: "task_match",
        execution_plan: "Execute task",
        estimated_credits: 200,
        estimated_duration: 30,
        confidence_score: 0.85
      }

      assert {:matched, match_result} = OrderBook.submit_proposal(proposal)
      assert match_result.proposal.status == :accepted
      assert match_result.demand.status == :matched
    end

    test "no match when proposal exceeds budget" do
      demand = %{
        client_id: "client_1",
        task_id: "task_no_match",
        required_capabilities: [],
        budget_ceiling: 50
      }

      OrderBook.post_demand(demand)

      proposal = %{
        agent_id: "agent_1",
        task_id: "task_no_match",
        execution_plan: "Expensive task",
        estimated_credits: 500,
        estimated_duration: 60,
        confidence_score: 0.9
      }

      assert :ok = OrderBook.submit_proposal(proposal)
    end

    test "colimit: accepting one rejects others" do
      demand = %{
        client_id: "client_1",
        task_id: "task_colimit",
        required_capabilities: [],
        budget_ceiling: 1000
      }

      # Submit two proposals first (no demand yet, so no auto-match)
      p1 = %{
        agent_id: "agent_1",
        task_id: "task_colimit",
        execution_plan: "Plan A",
        estimated_credits: 100,
        estimated_duration: 30,
        confidence_score: 0.9
      }

      p2 = %{
        agent_id: "agent_2",
        task_id: "task_colimit",
        execution_plan: "Plan B",
        estimated_credits: 200,
        estimated_duration: 60,
        confidence_score: 0.8
      }

      OrderBook.submit_proposal(p1)
      OrderBook.submit_proposal(p2)

      # Posting demand triggers match with cheapest (p1)
      {:matched, match_result} = OrderBook.post_demand(demand)
      assert match_result.proposal.agent_id == "agent_1"

      # All proposals for this task should be resolved
      remaining = OrderBook.proposals_for_task("task_colimit")
      assert remaining == []
    end
  end

  describe "best_proposal" do
    test "returns cheapest proposal" do
      OrderBook.submit_proposal(%{
        agent_id: "expensive",
        task_id: "task_best",
        execution_plan: "Expensive",
        estimated_credits: 500,
        estimated_duration: 60,
        confidence_score: 0.5
      })

      OrderBook.submit_proposal(%{
        agent_id: "cheap",
        task_id: "task_best",
        execution_plan: "Cheap",
        estimated_credits: 100,
        estimated_duration: 30,
        confidence_score: 0.9
      })

      {:ok, best} = OrderBook.best_proposal("task_best")
      # cost_functional: credits / (1 + confidence * 0.5)
      # cheap: 100 / (1 + 0.9*0.5) = 100/1.45 ≈ 69
      # expensive: 500 / (1 + 0.5*0.5) = 500/1.25 = 400
      assert best.agent_id == "cheap"
    end

    test "returns error when no proposals" do
      assert {:error, :no_proposals} = OrderBook.best_proposal("nonexistent")
    end
  end

  describe "depth" do
    test "returns proposal and demand counts" do
      assert {0, 0} = OrderBook.depth("task_depth")

      OrderBook.submit_proposal(%{
        agent_id: "a1",
        task_id: "task_depth",
        execution_plan: "Plan",
        estimated_credits: 100,
        estimated_duration: 30,
        confidence_score: 0.8
      })

      assert {1, 0} = OrderBook.depth("task_depth")
    end
  end
end
