defmodule AgentScheduler.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing agent process pools.

  Implements the OTP supervision model for AI agents, providing:

  - **Dynamic agent creation**: Agents are started on demand when jobs are assigned
  - **Fault isolation**: Individual agent crashes don't affect sibling agents
  - **Automatic restart**: Failed agents are restarted with their memoization store intact
  - **Graceful shutdown**: Agents are given time to checkpoint before termination
  - **Resource limits**: Maximum restart intensity prevents cascade failures

  ## Restart Strategy

  Uses `:one_for_one` — if an agent crashes, only that agent is restarted.
  This is appropriate because agents in the pool are independent (they don't
  share state). For pipeline stages with sequential dependencies, use
  `:rest_for_one` instead.

  ## Restart Intensity

  Configured with `max_restarts: 5` within `max_seconds: 60`. If an agent
  crashes more than 5 times in 60 seconds, the supervisor itself shuts down,
  propagating the failure to the application supervisor.

  ## Supervision Tree Position

      AgentScheduler.AppSupervisor (rest_for_one)
      └── AgentScheduler.Supervisor (DynamicSupervisor, one_for_one)
          ├── Agent "agent_001"
          ├── Agent "agent_002"
          └── Agent "agent_n"
  """

  use DynamicSupervisor
  require Logger

  # -- Client API --

  @doc """
  Starts the DynamicSupervisor for agent pools.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a new agent process under the supervisor.

  The agent is registered in `AgentScheduler.Registry` for O(1) lookup by ID.
  If an agent with the same ID already exists, returns `{:error, {:already_started, pid}}`.

  ## Parameters

    - `opts` — Keyword list passed to `AgentScheduler.Agent.start_link/1`:
      - `:id` (required) — Unique agent identifier
      - `:profile` (required) — Agent profile map
      - `:credits` — Initial credit balance (default: 0)
      - `:oversight` — Oversight mode (default: `:autonomous_escalation`)
      - `:max_retries` — Maximum retry attempts (default: 3)

  ## Returns

    - `{:ok, pid}` on success
    - `{:error, {:already_started, pid}}` if agent ID is taken
    - `{:error, reason}` on failure

  ## Examples

      AgentScheduler.Supervisor.start_agent(
        id: "web_tester_01",
        profile: %{name: "WebTester", capabilities: [:playwright, :k6]},
        credits: 500,
        oversight: :autonomous_escalation
      )
  """
  @spec start_agent(keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(opts) do
    id = Keyword.fetch!(opts, :id)

    child_spec = %{
      id: id,
      start: {AgentScheduler.Agent, :start_link, [opts]},
      restart: :transient,
      shutdown: :timer.seconds(30),
      type: :worker
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Agent #{id} started under supervisor (pid: #{inspect(pid)})")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Agent #{id} already running (pid: #{inspect(pid)})")
        {:error, {:already_started, pid}}

      {:error, reason} = error ->
        Logger.error("Failed to start agent #{id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops an agent process gracefully.

  The agent is given up to 30 seconds to checkpoint its state before termination.

  ## Parameters

    - `agent_id` — The ID of the agent to stop

  ## Returns

    - `:ok` on success
    - `{:error, :not_found}` if the agent doesn't exist
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id) do
    case Registry.lookup(AgentScheduler.Registry, agent_id) do
      [{pid, _}] ->
        Logger.info("Stopping agent #{agent_id} (pid: #{inspect(pid)})")
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all running agent PIDs and their IDs.
  """
  @spec list_agents() :: [{String.t(), pid()}]
  def list_agents do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, _} when is_pid(pid) ->
        case Registry.keys(AgentScheduler.Registry, pid) do
          [id] -> [{id, pid}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Returns the count of running agents.
  """
  @spec count_agents() :: non_neg_integer()
  def count_agents do
    %{active: active} = DynamicSupervisor.count_children(__MODULE__)
    active
  end

  @doc """
  Restarts an agent by stopping and re-starting it with the same options.

  This is used for manual recovery when an agent is in a bad state.
  The memoization store is lost on restart (by design — if you need
  persistent memoization, use external storage).
  """
  @spec restart_agent(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def restart_agent(agent_id, opts) do
    _ = stop_agent(agent_id)
    :timer.sleep(100)
    start_agent(Keyword.put(opts, :id, agent_id))
  end

  # -- Supervisor Callbacks --

  @impl true
  def init(_opts) do
    Logger.info("Agent pool supervisor started (strategy: one_for_one, max_restarts: 5/60s)")

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 60,
      extra_arguments: []
    )
  end
end
