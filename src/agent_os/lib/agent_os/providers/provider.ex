defmodule AgentOS.Providers.Provider do
  @moduledoc """
  Behaviour for agent execution providers.

  Providers manage the lifecycle of agents across different execution environments:
  local BEAM nodes, Fly.io machines, E2B sandboxes, cloud VMs, etc.

  Each provider implements the same interface so that higher-level orchestration
  code (planner, scheduler) can treat agents uniformly regardless of where they
  run. The deployment struct tracks provider-specific metadata while exposing a
  common status model.

  ## Status Lifecycle

      :pending → :running → :stopped
                    ↓
                 :failed

  ## Implementing a Provider

      defmodule MyProvider do
        @behaviour AgentOS.Providers.Provider

        @impl true
        def create_agent(config), do: ...
        # ... implement all callbacks
      end
  """

  @type agent_config :: %{
          type: atom(),
          name: String.t(),
          oversight: atom(),
          env: map(),
          resources: map()
        }

  @type deployment :: %{
          id: String.t(),
          provider: atom(),
          status: :pending | :running | :stopped | :failed,
          url: String.t() | nil,
          created_at: DateTime.t()
        }

  @doc """
  Creates a new agent deployment without starting it.

  Returns a deployment record with `:pending` status. The agent is provisioned
  but not yet executing work.
  """
  @callback create_agent(config :: agent_config()) ::
              {:ok, deployment()} | {:error, term()}

  @doc """
  Starts an agent that was previously created, assigning it a job.

  Transitions the deployment from `:pending` to `:running`.
  """
  @callback start_agent(deployment_id :: String.t(), job_spec :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Stops a running agent gracefully.

  The agent is given time to checkpoint before stopping.
  """
  @callback stop_agent(deployment_id :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Returns the current status of a deployment.
  """
  @callback status(deployment_id :: String.t()) ::
              {:ok, deployment()} | {:error, term()}

  @doc """
  Retrieves log output from an agent.

  ## Options

    * `:limit` — Maximum number of log lines (default: 100)
    * `:since` — Only return logs after this timestamp
  """
  @callback logs(deployment_id :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Lists all agent deployments managed by this provider.
  """
  @callback list_agents() :: {:ok, [deployment()]}

  @doc """
  Destroys an agent deployment permanently.

  Stops the agent if running and removes all associated resources.
  """
  @callback destroy_agent(deployment_id :: String.t()) ::
              :ok | {:error, term()}
end
