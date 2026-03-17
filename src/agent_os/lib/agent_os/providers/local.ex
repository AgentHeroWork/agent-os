defmodule AgentOS.Providers.Local do
  @moduledoc """
  Local provider — runs agents as GenServer processes in the current BEAM node.

  This is the default provider. Agents are managed via `AgentScheduler.Supervisor`
  and communicate through the local `AgentScheduler.Registry`. Deployment metadata
  is tracked in an ETS table (`:local_deployments`) so that the provider can map
  deployment IDs back to agent process IDs.

  ## When to Use

  Use the local provider for development, testing, and single-node production
  deployments. For distributed or isolated execution, use the Fly or E2B providers.
  """

  @behaviour AgentOS.Providers.Provider

  require Logger

  @ets_table :local_deployments

  # -- Public API --

  @doc """
  Ensures the ETS table for tracking local deployments exists.

  Called automatically by provider operations. Safe to call multiple times.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:named_table, :public, :set])
        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Creates a new agent on the local BEAM node.

  Looks up the agent type in `AgentScheduler.Agents.Registry` to get the profile,
  then starts the agent under `AgentScheduler.Supervisor`.
  """
  @impl true
  @spec create_agent(AgentOS.Providers.Provider.agent_config()) ::
          {:ok, AgentOS.Providers.Provider.deployment()} | {:error, term()}
  def create_agent(config) do
    ensure_table()

    deployment_id = generate_id()

    profile =
      case AgentScheduler.Agents.Registry.lookup(config.type) do
        {:ok, module} -> module.profile()
        {:error, _} -> %{name: config.name, capabilities: [], task_domain: [], input_schema: %{}, output_schema: %{}}
      end

    agent_opts = [
      id: deployment_id,
      profile: profile,
      oversight: Map.get(config, :oversight, :autonomous_escalation)
    ]

    case AgentScheduler.Supervisor.start_agent(agent_opts) do
      {:ok, pid} ->
        deployment = %{
          id: deployment_id,
          provider: :local,
          status: :pending,
          url: nil,
          created_at: DateTime.utc_now(),
          pid: pid,
          config: config
        }

        :ets.insert(@ets_table, {deployment_id, deployment})
        Logger.info("Local provider: created agent #{deployment_id} (type: #{config.type})")

        {:ok, deployment}

      {:error, reason} ->
        Logger.error("Local provider: failed to create agent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Starts a locally deployed agent by assigning it a job.
  """
  @impl true
  @spec start_agent(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_agent(deployment_id, job_spec) do
    ensure_table()

    case lookup_deployment(deployment_id) do
      {:ok, deployment} ->
        case AgentScheduler.Agent.assign_job(deployment_id, job_spec) do
          :ok ->
            updated = %{deployment | status: :running}
            :ets.insert(@ets_table, {deployment_id, updated})
            Logger.info("Local provider: started agent #{deployment_id}")
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Stops a locally running agent via the supervisor.
  """
  @impl true
  @spec stop_agent(String.t()) :: :ok | {:error, term()}
  def stop_agent(deployment_id) do
    ensure_table()

    case lookup_deployment(deployment_id) do
      {:ok, deployment} ->
        case AgentScheduler.Supervisor.stop_agent(deployment_id) do
          :ok ->
            updated = %{deployment | status: :stopped, pid: nil}
            :ets.insert(@ets_table, {deployment_id, updated})
            Logger.info("Local provider: stopped agent #{deployment_id}")
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the current status of a local deployment.

  Merges the ETS-tracked deployment metadata with live agent state from the
  GenServer process when available.
  """
  @impl true
  @spec status(String.t()) :: {:ok, AgentOS.Providers.Provider.deployment()} | {:error, term()}
  def status(deployment_id) do
    ensure_table()

    case lookup_deployment(deployment_id) do
      {:ok, deployment} ->
        # Enrich with live agent state if process is alive
        case AgentScheduler.Agent.get_state(deployment_id) do
          {:ok, agent_state} ->
            updated = %{deployment | status: map_agent_state(agent_state.state)}
            {:ok, updated}

          {:error, :not_found} ->
            {:ok, deployment}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns agent state and metrics as log entries.

  Since local agents don't produce traditional log output, this returns
  formatted state information from the GenServer process.
  """
  @impl true
  @spec logs(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def logs(deployment_id, _opts \\ []) do
    ensure_table()

    case AgentScheduler.Agent.get_state(deployment_id) do
      {:ok, agent_state} ->
        entries = [
          "[#{DateTime.utc_now() |> DateTime.to_iso8601()}] Agent #{deployment_id} state: #{agent_state.state}",
          "[#{DateTime.utc_now() |> DateTime.to_iso8601()}] Metrics: #{inspect(agent_state.metrics)}",
          "[#{DateTime.utc_now() |> DateTime.to_iso8601()}] Oversight: #{agent_state.oversight}",
          "[#{DateTime.utc_now() |> DateTime.to_iso8601()}] Memo store size: #{map_size(agent_state.memo_store)}"
        ]

        {:ok, entries}

      {:error, :not_found} ->
        {:ok, ["[#{DateTime.utc_now() |> DateTime.to_iso8601()}] Agent #{deployment_id} not running"]}
    end
  end

  @doc """
  Lists all locally tracked deployments.
  """
  @impl true
  @spec list_agents() :: {:ok, [AgentOS.Providers.Provider.deployment()]}
  def list_agents do
    ensure_table()

    deployments =
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_id, deployment} -> deployment end)

    {:ok, deployments}
  end

  @doc """
  Destroys a local agent — stops it and removes tracking metadata.
  """
  @impl true
  @spec destroy_agent(String.t()) :: :ok | {:error, term()}
  def destroy_agent(deployment_id) do
    ensure_table()

    # Stop the agent if it's running (ignore :not_found errors)
    case AgentScheduler.Supervisor.stop_agent(deployment_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.warning("Local provider: error stopping agent #{deployment_id}: #{inspect(reason)}")
    end

    :ets.delete(@ets_table, deployment_id)
    Logger.info("Local provider: destroyed agent #{deployment_id}")
    :ok
  end

  # -- Private Helpers --

  @spec lookup_deployment(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp lookup_deployment(deployment_id) do
    case :ets.lookup(@ets_table, deployment_id) do
      [{^deployment_id, deployment}] -> {:ok, deployment}
      [] -> {:error, :not_found}
    end
  end

  @spec map_agent_state(atom()) :: :pending | :running | :stopped | :failed
  defp map_agent_state(:pending), do: :pending
  defp map_agent_state(:running), do: :running
  defp map_agent_state(:checkpointed), do: :running
  defp map_agent_state(:waiting_approval), do: :running
  defp map_agent_state(:completed), do: :stopped
  defp map_agent_state(:cancelled), do: :stopped
  defp map_agent_state(:failed), do: :failed
  defp map_agent_state(_), do: :pending

  @spec generate_id() :: String.t()
  defp generate_id do
    "local_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
