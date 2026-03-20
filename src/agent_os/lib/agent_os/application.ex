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

  require Logger

  @impl true
  def start(_type, _args) do
    check_llm_config()

    children = [AgentOS.Audit]

    opts = [strategy: :one_for_one, name: AgentOS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp check_llm_config do
    openai = System.get_env("OPENAI_API_KEY")
    anthropic = System.get_env("ANTHROPIC_API_KEY")

    cond do
      openai && openai != "" ->
        Logger.info("AgentOS: LLM provider configured (OpenAI)")

      anthropic && anthropic != "" ->
        Logger.info("AgentOS: LLM provider configured (Anthropic)")

      true ->
        Logger.warning(
          "AgentOS: No LLM API key found. Set OPENAI_API_KEY or ANTHROPIC_API_KEY. " <>
            "Falling back to Ollama at localhost:11434."
        )
    end
  end
end
