defmodule AgentOS.Application do
  @moduledoc """
  OTP Application for the AI Operating System.

  Starts all four subsystems under a single supervision tree,
  ensuring proper startup ordering and fault isolation:

      AgentOS.Supervisor (one_for_one)
      ├── MemoryLayer        (must start first — other subsystems depend on it)
      ├── ToolInterface      (depends on memory for capability storage)
      ├── AgentScheduler     (depends on tools and memory)
      └── PlannerEngine      (depends on all three — the orchestration layer)

  The startup order reflects the categorical dependency:
  Memory (functor) → Tools (morphisms) → Agents (objects) → Planner (natural transformation)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Layer 1: Memory — foundation for all state
      {MemoryLayer, []},

      # Layer 2: Tools — interface to external capabilities
      {ToolInterface, []},

      # Layer 3: Scheduler — agent lifecycle management
      {AgentScheduler, []},

      # Layer 4: Planner — orchestration and market dynamics
      {PlannerEngine, []}
    ]

    opts = [strategy: :one_for_one, name: AgentOS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
