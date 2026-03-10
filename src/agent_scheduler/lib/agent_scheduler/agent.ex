defmodule AgentScheduler.Agent do
  @moduledoc """
  GenServer managing an individual agent's lifecycle.

  Each agent is an autonomous unit of computation with a well-defined state machine,
  analogous to an OS process. The lifecycle states mirror the Agent-Hero execution
  pipeline:

      :pending → :running → :waiting_approval → :completed
                    ↓              ↓
               :checkpointed    :failed → :pending (retry)
                    ↓
                 :running

  ## Durable Execution

  The agent implements Inngest-style durable execution via a memoization store.
  Each step function is identified by a unique key. If the agent crashes and is
  restarted by its supervisor, completed steps are replayed from the memoization
  store without re-execution. This guarantees idempotent recovery.

  ## Oversight Modes

  Three oversight modes govern human intervention:

    - `:supervised` — Human reviews every step before proceeding
    - `:spot_check` — Human periodically reviews random steps
    - `:autonomous_escalation` — Agent runs autonomously, escalates when confidence < threshold

  These form a lattice: supervised ≥ spot_check ≥ autonomous_escalation.

  ## Registration

  Agents are registered via `AgentScheduler.Registry` for O(1) lookup by ID.
  """

  use GenServer
  require Logger

  # -- Types --

  @type agent_id :: String.t()
  @type oversight :: :supervised | :spot_check | :autonomous_escalation
  @type lifecycle_state ::
          :pending
          | :running
          | :waiting_approval
          | :checkpointed
          | :completed
          | :failed
          | :cancelled

  @type step_id :: String.t()

  @type profile :: %{
          name: String.t(),
          capabilities: [atom()],
          task_domain: [atom()],
          input_schema: map(),
          output_schema: map()
        }

  @type t :: %__MODULE__{
          id: agent_id(),
          profile: profile(),
          state: lifecycle_state(),
          credits: non_neg_integer(),
          metrics: map(),
          oversight: oversight(),
          memo_store: %{step_id() => term()},
          current_job: map() | nil,
          retry_count: non_neg_integer(),
          max_retries: non_neg_integer(),
          started_at: integer() | nil,
          checkpoint_data: term()
        }

  defstruct [
    :id,
    :profile,
    :started_at,
    :current_job,
    :checkpoint_data,
    state: :pending,
    credits: 0,
    metrics: %{},
    oversight: :autonomous_escalation,
    memo_store: %{},
    retry_count: 0,
    max_retries: 3
  ]

  # -- Client API --

  @doc """
  Starts an agent process linked to the calling supervisor.

  ## Options

    - `:id` (required) — Unique agent identifier
    - `:profile` (required) — Agent profile map with capabilities and schemas
    - `:credits` — Initial credit balance (default: 0)
    - `:oversight` — Oversight mode (default: `:autonomous_escalation`)
    - `:max_retries` — Maximum retry attempts on failure (default: 3)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    GenServer.start_link(__MODULE__, opts,
      name: via_registry(id)
    )
  end

  @doc """
  Executes a durable step function with memoization.

  If the step has been previously completed (its ID exists in the memoization store),
  the cached result is returned without re-executing the function. This is the core
  mechanism for crash recovery: on restart, all previously completed steps are
  replayed from the memo store.

  ## Parameters

    - `agent_id` — The agent to execute the step on
    - `step_id` — Unique identifier for the step (used as memoization key)
    - `fun` — Zero-arity function to execute

  ## Returns

    - `{:ok, result}` — The step result (from execution or cache)
    - `{:error, reason}` — If the step fails
  """
  @spec execute_step(agent_id(), step_id(), (-> term())) ::
          {:ok, term()} | {:error, term()}
  def execute_step(agent_id, step_id, fun) when is_function(fun, 0) do
    GenServer.call(via_registry(agent_id), {:execute_step, step_id, fun}, :timer.minutes(5))
  end

  @doc """
  Assigns a job to this agent and transitions to `:running` state.
  """
  @spec assign_job(agent_id(), map()) :: :ok | {:error, term()}
  def assign_job(agent_id, job) do
    GenServer.call(via_registry(agent_id), {:assign_job, job})
  end

  @doc """
  Requests human approval (transitions to `:waiting_approval` state).

  Only valid when oversight mode is `:supervised` or when the agent
  explicitly escalates under `:autonomous_escalation`.
  """
  @spec request_approval(agent_id(), term()) :: :ok | {:error, term()}
  def request_approval(agent_id, artifact) do
    GenServer.call(via_registry(agent_id), {:request_approval, artifact})
  end

  @doc """
  Provides human approval or rejection for a pending approval request.
  """
  @spec respond_approval(agent_id(), :approve | :reject, String.t()) :: :ok | {:error, term()}
  def respond_approval(agent_id, decision, feedback \\ "") do
    GenServer.call(via_registry(agent_id), {:respond_approval, decision, feedback})
  end

  @doc """
  Creates a checkpoint of the current agent state for crash recovery.
  """
  @spec checkpoint(agent_id()) :: :ok | {:error, term()}
  def checkpoint(agent_id) do
    GenServer.call(via_registry(agent_id), :checkpoint)
  end

  @doc """
  Returns the current state of the agent.
  """
  @spec get_state(agent_id()) :: {:ok, t()} | {:error, :not_found}
  def get_state(agent_id) do
    GenServer.call(via_registry(agent_id), :get_state)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Signals the agent to complete its current job.
  """
  @spec complete(agent_id(), term()) :: :ok | {:error, term()}
  def complete(agent_id, result) do
    GenServer.call(via_registry(agent_id), {:complete, result})
  end

  @doc """
  Cancels the agent's current job.
  """
  @spec cancel(agent_id()) :: :ok | {:error, term()}
  def cancel(agent_id) do
    GenServer.cast(via_registry(agent_id), :cancel)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      profile: Keyword.fetch!(opts, :profile),
      state: :pending,
      credits: Keyword.get(opts, :credits, 0),
      oversight: Keyword.get(opts, :oversight, :autonomous_escalation),
      max_retries: Keyword.get(opts, :max_retries, 3),
      memo_store: %{},
      metrics: %{
        steps_completed: 0,
        steps_cached: 0,
        total_execution_ms: 0,
        errors: 0
      }
    }

    Logger.info("Agent #{state.id} started in :pending state (oversight: #{state.oversight})")
    emit_telemetry(:agent_started, state)

    {:ok, state}
  end

  @impl true
  def handle_call({:execute_step, step_id, fun}, _from, %{state: agent_state} = state)
      when agent_state in [:running, :checkpointed] do
    case Map.get(state.memo_store, step_id) do
      nil ->
        # Step not memoized — execute and store result
        start_time = System.monotonic_time(:microsecond)

        try do
          result = fun.()
          elapsed = System.monotonic_time(:microsecond) - start_time

          new_state =
            state
            |> put_in([Access.key(:memo_store), step_id], result)
            |> update_in([Access.key(:metrics), :steps_completed], &(&1 + 1))
            |> update_in([Access.key(:metrics), :total_execution_ms], &(&1 + div(elapsed, 1000)))
            |> Map.put(:state, :running)

          Logger.debug("Agent #{state.id}: step #{step_id} completed in #{div(elapsed, 1000)}ms")
          emit_telemetry(:step_completed, %{agent_id: state.id, step_id: step_id, elapsed_us: elapsed})

          {:reply, {:ok, result}, new_state}
        rescue
          error ->
            new_state = update_in(state, [Access.key(:metrics), :errors], &(&1 + 1))
            Logger.error("Agent #{state.id}: step #{step_id} failed: #{inspect(error)}")
            emit_telemetry(:step_failed, %{agent_id: state.id, step_id: step_id, error: error})

            {:reply, {:error, error}, new_state}
        end

      cached_result ->
        # Step already memoized — replay from cache (durable execution)
        new_state = update_in(state, [Access.key(:metrics), :steps_cached], &(&1 + 1))

        Logger.debug("Agent #{state.id}: step #{step_id} replayed from memo store")
        emit_telemetry(:step_replayed, %{agent_id: state.id, step_id: step_id})

        {:reply, {:ok, cached_result}, new_state}
    end
  end

  def handle_call({:execute_step, _step_id, _fun}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state, :expected, [:running, :checkpointed]}}, state}
  end

  @impl true
  def handle_call({:assign_job, job}, _from, %{state: :pending} = state) do
    new_state = %{state | state: :running, current_job: job, started_at: System.monotonic_time(:millisecond)}

    Logger.info("Agent #{state.id}: assigned job #{inspect(job[:id] || :anonymous)}")
    emit_telemetry(:job_assigned, %{agent_id: state.id, job: job})

    {:reply, :ok, new_state}
  end

  def handle_call({:assign_job, _job}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state, :expected, [:pending]}}, state}
  end

  @impl true
  def handle_call({:request_approval, artifact}, _from, %{state: :running} = state) do
    case state.oversight do
      :supervised ->
        new_state = %{state | state: :waiting_approval, checkpoint_data: artifact}
        Logger.info("Agent #{state.id}: requesting approval (supervised mode)")
        emit_telemetry(:approval_requested, %{agent_id: state.id})
        {:reply, :ok, new_state}

      :spot_check ->
        # Probabilistic check — 30% chance of requiring approval
        if :rand.uniform() < 0.3 do
          new_state = %{state | state: :waiting_approval, checkpoint_data: artifact}
          Logger.info("Agent #{state.id}: spot check triggered, requesting approval")
          {:reply, :ok, new_state}
        else
          {:reply, :ok, state}
        end

      :autonomous_escalation ->
        new_state = %{state | state: :waiting_approval, checkpoint_data: artifact}
        Logger.info("Agent #{state.id}: escalating to human review (low confidence)")
        emit_telemetry(:escalation, %{agent_id: state.id})
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:request_approval, _artifact}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state, :expected, [:running]}}, state}
  end

  @impl true
  def handle_call({:respond_approval, :approve, _feedback}, _from, %{state: :waiting_approval} = state) do
    new_state = %{state | state: :running, checkpoint_data: nil}
    Logger.info("Agent #{state.id}: approval granted, resuming execution")
    {:reply, :ok, new_state}
  end

  def handle_call({:respond_approval, :reject, feedback}, _from, %{state: :waiting_approval} = state) do
    if state.retry_count < state.max_retries do
      new_state = %{state | state: :pending, retry_count: state.retry_count + 1, checkpoint_data: nil}
      Logger.warning("Agent #{state.id}: approval rejected (#{feedback}), retrying (#{new_state.retry_count}/#{state.max_retries})")
      {:reply, :ok, new_state}
    else
      new_state = %{state | state: :failed, checkpoint_data: nil}
      Logger.error("Agent #{state.id}: approval rejected, max retries exceeded")
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:respond_approval, _, _}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state, :expected, [:waiting_approval]}}, state}
  end

  @impl true
  def handle_call(:checkpoint, _from, %{state: :running} = state) do
    checkpoint_data = %{
      memo_store: state.memo_store,
      metrics: state.metrics,
      current_job: state.current_job,
      timestamp: System.monotonic_time(:millisecond)
    }

    new_state = %{state | state: :checkpointed, checkpoint_data: checkpoint_data}
    Logger.info("Agent #{state.id}: checkpoint created (#{map_size(state.memo_store)} memoized steps)")
    emit_telemetry(:checkpoint_created, %{agent_id: state.id, steps: map_size(state.memo_store)})

    {:reply, :ok, new_state}
  end

  def handle_call(:checkpoint, _from, state) do
    {:reply, {:error, {:invalid_state, state.state, :expected, [:running]}}, state}
  end

  @impl true
  def handle_call({:complete, result}, _from, %{state: agent_state} = state)
      when agent_state in [:running, :checkpointed] do
    elapsed =
      if state.started_at,
        do: System.monotonic_time(:millisecond) - state.started_at,
        else: 0

    new_state = %{state | state: :completed, checkpoint_data: result}
    Logger.info("Agent #{state.id}: job completed in #{elapsed}ms")

    # Submit evaluation to the evaluator
    evaluation_input = %{
      agent_id: state.id,
      result: result,
      metrics: state.metrics,
      elapsed_ms: elapsed,
      retry_count: state.retry_count
    }

    emit_telemetry(:job_completed, evaluation_input)
    {:reply, :ok, new_state}
  end

  def handle_call({:complete, _result}, _from, state) do
    {:reply, {:error, {:invalid_state, state.state, :expected, [:running, :checkpointed]}}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_cast(:cancel, %{state: agent_state} = state)
      when agent_state in [:pending, :running, :waiting_approval, :checkpointed] do
    new_state = %{state | state: :cancelled}
    Logger.info("Agent #{state.id}: cancelled from #{agent_state} state")
    emit_telemetry(:agent_cancelled, %{agent_id: state.id, from_state: agent_state})
    {:noreply, new_state}
  end

  def handle_cast(:cancel, state) do
    Logger.warning("Agent #{state.id}: cancel ignored in #{state.state} state")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Agent #{state.id}: terminating (reason: #{inspect(reason)}, state: #{state.state})")
    emit_telemetry(:agent_terminated, %{agent_id: state.id, reason: reason})
    :ok
  end

  # -- Private Helpers --

  defp via_registry(agent_id) do
    {:via, Registry, {AgentScheduler.Registry, agent_id}}
  end

  defp emit_telemetry(event, measurements) when is_atom(event) do
    :telemetry.execute(
      [:agent_scheduler, :agent, event],
      %{system_time: System.system_time()},
      measurements
    )
  rescue
    # Telemetry may not be started in test environments
    _ -> :ok
  end
end
