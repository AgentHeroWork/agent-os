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
    # All subsystems (MemoryLayer, ToolInterface, AgentScheduler, PlannerEngine,
    # AgentOS.Web) are separate OTP applications that start automatically as
    # deps via mix.exs. This supervisor exists for any agent_os-specific
    # processes (e.g., future background tasks).
    children = []

    opts = [strategy: :one_for_one, name: AgentOS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
