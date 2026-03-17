defmodule AgentScheduler.Agents.AgentType do
  @moduledoc """
  Behaviour defining the contract for agent types.

  Each agent type (OpenClaw, NemoClaw, etc.) implements this behaviour to declare
  its profile, tool requirements, and autonomous execution logic. The scheduler uses
  these callbacks to configure agents at startup and route tool access.

  ## Autonomous Execution

  Agents implement `run_autonomous/2` to own their full execution pipeline:
  research, LaTeX generation, PDF compilation, GitHub publishing, and self-repair.
  The orchestrator (AgentRunner) only monitors, validates outputs against contracts,
  and handles escalation when agents get stuck.

  The legacy `execute_step/3` callback is retained as optional for testing and
  streaming use cases.
  """

  @type step_context :: %{
          agent_id: String.t(),
          job: map(),
          memory: map(),
          step_number: non_neg_integer()
        }

  @type step_result :: {:ok, term()} | {:error, term()} | {:escalate, term()}

  @type autonomous_result ::
          {:ok, %{artifacts: map(), metadata: map()}}
          | {:error, term()}
          | {:escalate, %{reason: atom(), message: String.t(), context: map(), partial_artifacts: map()}}

  @doc """
  Returns the agent type's static profile: name, capabilities, default oversight.
  """
  @callback profile() :: %{
              name: String.t(),
              capabilities: [atom()],
              task_domain: [atom()],
              default_oversight: :supervised | :spot_check | :autonomous_escalation,
              description: String.t()
            }

  @doc """
  Runs the agent's full autonomous pipeline.

  The agent owns everything: research, generation, compilation, publishing,
  and self-repair. Returns `{:ok, %{artifacts: ..., metadata: ...}}` on success,
  `{:error, reason}` on failure, or `{:escalate, detail}` to request help.
  """
  @callback run_autonomous(input :: map(), context :: map()) :: autonomous_result()

  @doc """
  Executes a single step of the agent's work loop (optional).

  Retained for testing, streaming, and incremental execution use cases.
  Returns `{:ok, result}` to proceed, `{:error, reason}` to fail,
  or `{:escalate, artifact}` to request human review.
  """
  @callback execute_step(step_id :: String.t(), input :: map(), context :: step_context()) ::
              step_result()

  @doc """
  Returns the list of tool IDs this agent type requires.
  Used by the scheduler to grant capability tokens at startup.
  """
  @callback tool_requirements() :: [String.t()]

  @optional_callbacks [execute_step: 3]
end
