defmodule PlannerEngine do
  @moduledoc """
  PlannerEngine — Order Book Dynamics and Natural Transformation.

  The planner engine is the highest-level orchestration primitive in the AI OS,
  analogous to systemd/init in classical operating systems. It formalizes planning
  as a natural transformation η: F ⇒ G between the task functor F (mapping jobs
  to requirements) and the capability functor G (mapping agents to capabilities).

  The engine comprises five subsystems:

    * `PlannerEngine.OrderBook` — Profunctor-based order book with matching engine
    * `PlannerEngine.Escrow` — Escrow monad with Mnesia-backed transactions
    * `PlannerEngine.Decomposer` — Functorial job decomposition into DAGs
    * `PlannerEngine.Reputation` — 6-dimensional quality scoring and trust
    * `PlannerEngine.Market` — Market clearing (colimit) and revenue distribution

  ## Architecture

  The application follows standard OTP conventions with a `:one_for_one` supervision
  strategy. Each subsystem is an independent GenServer that can crash and restart
  without affecting the others.

  ## Job Lifecycle

      draft → open → in_progress → review → completed
                                          → cancelled
                                          → disputed

  ## Usage

      # Start the application
      {:ok, _pid} = Application.ensure_all_started(:planner_engine)

      # Post a job demand
      demand = %{
        client_id: "client_1",
        task_id: "task_42",
        required_capabilities: [:playwright, :k6],
        budget_ceiling: 5000,
        deadline: ~U[2026-03-11 00:00:00Z]
      }
      :ok = PlannerEngine.OrderBook.post_demand(demand)

      # Submit an agent proposal
      proposal = %{
        agent_id: "agent_1",
        task_id: "task_42",
        execution_plan: "Run E2E tests with Playwright, then k6 load tests",
        estimated_credits: 3500,
        estimated_duration: 180,
        confidence_score: 0.92
      }
      :ok = PlannerEngine.OrderBook.submit_proposal(proposal)

      # Clear the market for a task
      {:ok, contract} = PlannerEngine.Market.clear_market("task_42")
  """

  @doc """
  Returns the current version of the PlannerEngine.
  """
  @spec version() :: String.t()
  def version, do: "0.1.0"
end

defmodule PlannerEngine.Application do
  @moduledoc """
  OTP Application for the PlannerEngine.

  Starts a supervision tree with `:one_for_one` strategy containing:

    * `PlannerEngine.OrderBook` — order book GenServer
    * `PlannerEngine.Escrow` — escrow GenServer (initializes Mnesia tables)
    * `PlannerEngine.Reputation` — reputation engine GenServer
    * `PlannerEngine.Market` — market clearing GenServer
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {PlannerEngine.Escrow, []},
      {PlannerEngine.OrderBook, []},
      {PlannerEngine.Reputation, []},
      {PlannerEngine.Market, []}
    ]

    opts = [strategy: :one_for_one, name: PlannerEngine.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
