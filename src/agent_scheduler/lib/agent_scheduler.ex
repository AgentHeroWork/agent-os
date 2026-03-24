defmodule AgentScheduler do
  @moduledoc """
  AI Agent Scheduler — OTP-based process management for AI agent orchestration.

  This is the top-level application module that starts the supervision tree for
  the entire agent scheduling system. The architecture mirrors OS process management:

  - **AgentScheduler.Scheduler** — Priority-based, credit-weighted scheduling (analogous to Linux CFS)
  - **AgentScheduler.Supervisor** — DynamicSupervisor for agent pools (analogous to OTP supervision trees)
  - **AgentScheduler.Agent** — Individual agent lifecycle management (analogous to OS processes)
  - **AgentScheduler.Evaluator** — 6-dimensional quality evaluation and reputation computation

  ## Supervision Tree

      AgentScheduler (Application)
      ├── Registry (unique, :agent_registry)
      ├── AgentScheduler.Evaluator
      ├── AgentScheduler.Scheduler
      └── AgentScheduler.Supervisor (DynamicSupervisor)
          ├── Agent_1
          ├── Agent_2
          └── Agent_n

  The tree uses `:rest_for_one` strategy at the top level: if the Registry crashes,
  all downstream components that depend on it are restarted in order. The
  DynamicSupervisor uses `:one_for_one` so individual agent failures are isolated.

  ## Execution Pipeline

  Follows the Agent-Hero model:
  Job → Proposal → Contract → Decomposition → Execution → Evaluation

  Each transition is a morphism in the execution category, with durable execution
  (Inngest-style memoization) ensuring idempotent replay on crash recovery.
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AgentScheduler.Registry},
      {AgentScheduler.Agents.Registry, []},
      {AgentScheduler.Evaluator, []},
      {AgentScheduler.Scheduler, []},
      {AgentScheduler.Supervisor, []}
    ]

    opts = [
      strategy: :rest_for_one,
      name: AgentScheduler.AppSupervisor,
      max_restarts: 10,
      max_seconds: 60
    ]

    Supervisor.start_link(children, opts)
  end

  @doc """
  Submits a job to the agent scheduling system.

  This is the primary entry point for clients. The job flows through the
  full execution pipeline: scheduling → agent assignment → execution → evaluation.

  ## Parameters

    - `client_id` — The client submitting the job
    - `job` — A map containing `:task`, `:input`, `:oversight`, and optional `:priority`
    - `opts` — Additional options (`:timeout`, `:max_retries`)

  ## Returns

    - `{:ok, job_id}` on successful submission
    - `{:error, reason}` on failure

  ## Examples

      iex> AgentScheduler.submit_job("client_1", %{
      ...>   task: :web_testing,
      ...>   input: %{url: "https://example.com"},
      ...>   oversight: :autonomous_escalation
      ...> })
      {:ok, "job_abc123"}
  """
  @spec submit_job(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def submit_job(client_id, job, opts \\ []) do
    job_id = generate_job_id()

    job_spec = %{
      id: job_id,
      client_id: client_id,
      task: Map.fetch!(job, :task),
      input: Map.fetch!(job, :input),
      oversight: Map.get(job, :oversight, :autonomous_escalation),
      priority: Map.get(job, :priority, :marketplace),
      max_retries: Keyword.get(opts, :max_retries, 3),
      timeout: Keyword.get(opts, :timeout, :timer.minutes(30)),
      submitted_at: System.monotonic_time(:millisecond)
    }

    case AgentScheduler.Scheduler.enqueue(client_id, job_spec) do
      :ok -> {:ok, job_id}
      {:error, _} = error -> error
    end
  end

  @doc """
  Starts an agent in the supervised pool.

  The agent is registered under the DynamicSupervisor and can be looked up
  by ID through the Registry.
  """
  @spec start_agent(String.t(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(agent_id, profile, opts \\ []) do
    AgentScheduler.Supervisor.start_agent(
      id: agent_id,
      profile: profile,
      credits: Keyword.get(opts, :credits, 0),
      oversight: Keyword.get(opts, :oversight, :autonomous_escalation)
    )
  end

  @doc """
  Returns the evaluation scores for an agent.
  """
  @spec get_evaluation(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_evaluation(agent_id) do
    AgentScheduler.Evaluator.get_scores(agent_id)
  end

  @doc """
  Starts an OpenClaw agent in the supervised pool.

  OpenClaw agents have full tool access and default to `:autonomous_escalation` oversight.
  """
  @spec start_openclaw(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_openclaw(name, opts \\ []) do
    case AgentScheduler.Agents.Registry.lookup(:openclaw) do
      {:ok, module} ->
        profile = module.profile()
        agent_id = "openclaw_#{name}_#{:erlang.unique_integer([:positive])}"
        oversight = Keyword.get(opts, :oversight, profile.default_oversight)
        start_agent(agent_id, profile, Keyword.merge(opts, oversight: oversight))

      {:error, :not_found} ->
        {:error, :openclaw_not_registered}
    end
  end

  @doc """
  Starts a NemoClaw agent in the supervised pool.

  NemoClaw agents have restricted tools and default to `:supervised` oversight.
  """
  @spec start_nemoclaw(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_nemoclaw(name, opts \\ []) do
    case AgentScheduler.Agents.Registry.lookup(:nemoclaw) do
      {:ok, module} ->
        profile = module.profile()
        agent_id = "nemoclaw_#{name}_#{:erlang.unique_integer([:positive])}"
        oversight = Keyword.get(opts, :oversight, profile.default_oversight)
        start_agent(agent_id, profile, Keyword.merge(opts, oversight: oversight))

      {:error, :not_found} ->
        {:error, :nemoclaw_not_registered}
    end
  end

  # -- Private --

  defp generate_job_id do
    "job_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
