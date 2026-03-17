defmodule AgentOS do
  @moduledoc """
  The AI Operating System — Unified Runtime for Intelligent Agents.

  AgentOS composes four core subsystems into a unified operating system
  for AI agents, following the categorical principle that complex systems
  emerge from the composition of well-defined abstractions:

    * `AgentScheduler` — Process management for agents (Objects in a category)
    * `ToolInterface` — Capability-based tool access (Morphisms between objects)
    * `MemoryLayer` — Typed persistent memory (Functors preserving structure)
    * `PlannerEngine` — Market-based orchestration (Natural transformations)

  ## Architecture

  Built on Erlang/OTP's BEAM VM, AgentOS leverages:

    * **Supervision trees** for fault-tolerant agent lifecycle management
    * **GenServer** processes for stateful agent, tool, and memory abstractions
    * **ETS/Mnesia** for high-performance typed memory storage
    * **Message passing** for inter-agent communication without shared state
    * **Lightweight processes** for massive agent concurrency

  ## Categorical Foundation

  The four subsystems form a commutative diagram:

      Agents ──Tools──→ Actions
        │                  │
      Memory            Planner
        │                  │
        ▼                  ▼
      Knowledge ────────→ Goals

  Where composition of any path yields equivalent results (naturality).
  """

  @doc """
  Start the AI Operating System with the given configuration.

  ## Options

    * `:scheduler_config` — Configuration for the agent scheduler
    * `:tool_config` — Tool registry and capability settings
    * `:memory_config` — Memory backend configuration
    * `:planner_config` — Market and orchestration settings

  ## Examples

      AgentOS.start(scheduler_config: %{max_agents: 1000})

  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    AgentOS.Application.start(:normal, opts)
  end

  @doc """
  Submit a job to the AI Operating System.

  The job will be decomposed by the planner, matched to agents via the
  order book, and executed through the scheduler with tool access and
  memory persistence.
  """
  @spec submit_job(map()) :: {:ok, String.t()} | {:error, term()}
  def submit_job(job_spec) do
    PlannerEngine.OrderBook.post_demand(job_spec)
  end

  @doc """
  Query the current system status across all subsystems.
  """
  @spec status() :: map()
  def status do
    %{
      scheduler: %{running: true},
      tools: ToolInterface.list_tools(),
      memory: %{running: true},
      planner: %{running: true}
    }
  end

  @doc "Creates an agent from a complete AgentSpec."
  @spec create_agent(AgentOS.AgentSpec.t()) :: {:ok, String.t()} | {:error, term()}
  def create_agent(spec) do
    resolved = AgentOS.AgentSpec.resolve_credentials(spec)

    case AgentOS.AgentSpec.validate(resolved) do
      :ok ->
        provider = AgentOS.Providers.Resolver.resolve(resolved.provider)

        provider.create_agent(%{
          type: resolved.type,
          name: resolved.name,
          oversight: resolved.oversight,
          env: credential_env(resolved.credentials),
          resources: resolved.resources
        })

      {:error, _} = err ->
        err
    end
  end

  defp credential_env(creds) do
    %{}
    |> maybe_put("GITHUB_TOKEN", creds[:github_token])
    |> maybe_put("FLY_API_TOKEN", creds[:fly_api_token])
    |> maybe_put("AGENT_OS_API_KEY", creds[:agent_os_api_key])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
