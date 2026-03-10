defmodule ToolInterface do
  @moduledoc """
  AI OS Tool Interface Layer.

  Provides a capability-based tool registry with three tiers (Builtin, Sandbox, MCP),
  sandboxed execution via isolated BEAM processes, and per-invocation audit logging.

  ## Architecture

  The tool interface layer mediates between AI agents and external systems,
  analogous to device drivers in a classical operating system. Tools are
  organised into three trust tiers:

  - **Builtin**: Statically defined, trusted operations (web-search, text-transform, etc.)
  - **Sandbox**: Code execution in isolated environments (code-exec, shell-exec, etc.)
  - **MCP**: Runtime-discovered tools from Model Context Protocol servers

  ## Usage

      # Register a capability for an agent
      {:ok, token} = ToolInterface.grant_capability("agent-1", "web-search", [:invoke])

      # Invoke a tool with capability checking
      {:ok, result} = ToolInterface.invoke("agent-1", "web-search", %{query: "elixir otp"}, token)

      # Discover MCP tools
      :ok = ToolInterface.discover_mcp("my-server", "https://mcp.example.com", "bearer-token")

      # Freeze tool configuration for execution
      :ok = ToolInterface.freeze()
  """

  alias ToolInterface.{Registry, Capability, Sandbox, Audit}

  @type invoke_result :: {:ok, any()} | {:error, term()}

  @doc """
  Invokes a tool with capability-based authorization, input validation,
  sandboxed execution (for sandbox-tier tools), and audit logging.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec invoke(String.t(), String.t(), map(), Capability.t()) :: invoke_result()
  def invoke(agent_id, tool_id, input, capability_token) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, _token} <- Capability.authorize(capability_token, tool_id),
         {:ok, tool_spec} <- Registry.lookup(tool_id),
         :ok <- validate_input(tool_spec, input) do
      result = execute_tool(tool_spec, input)
      duration = System.monotonic_time(:millisecond) - start_time
      status = if match?({:ok, _}, result), do: :ok, else: :error

      Audit.log_invocation(agent_id, tool_id, input, result, duration, status)
      result
    else
      {:error, _reason} = error ->
        duration = System.monotonic_time(:millisecond) - start_time
        Audit.log_invocation(agent_id, tool_id, input, error, duration, :error)
        error
    end
  end

  @doc """
  Grants a capability token to an agent for a specific tool.

  ## Options

  - `:permissions` — list of permissions (default: `[:invoke]`)
  - `:rate_limit` — maximum invocations per minute (default: `60`)
  - `:ttl_seconds` — token time-to-live in seconds (default: `3600`)
  """
  @spec grant_capability(String.t(), String.t(), keyword()) ::
          {:ok, Capability.t()} | {:error, term()}
  def grant_capability(agent_id, tool_id, opts \\ []) do
    permissions = Keyword.get(opts, :permissions, [:invoke])
    rate_limit = Keyword.get(opts, :rate_limit, 60)
    ttl = Keyword.get(opts, :ttl_seconds, 3600)

    Capability.create(agent_id, tool_id, permissions, rate_limit, ttl)
  end

  @doc """
  Discovers tools from an MCP server and registers them in the tool registry.
  Tools are namespaced as `"server_name__tool_name"`.
  """
  @spec discover_mcp(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def discover_mcp(server_name, url, token) do
    ToolInterface.MCPClient.discover_and_register(server_name, url, token)
  end

  @doc """
  Freezes the tool registry, preventing any further tool registration.
  Implements contract-locked configuration for agent execution.
  """
  @spec freeze() :: :ok
  def freeze do
    Registry.freeze()
  end

  @doc """
  Lists all registered tools, optionally filtered by tier.
  """
  @spec list_tools(atom() | nil) :: [map()]
  def list_tools(tier \\ nil) do
    Registry.list(tier)
  end

  # ---------- Private ----------

  defp validate_input(tool_spec, input) do
    case tool_spec.validate do
      nil ->
        :ok

      validate_fn when is_function(validate_fn, 1) ->
        case validate_fn.(input) do
          :ok -> :ok
          {:ok, _validated} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp execute_tool(%{tier: :sandbox} = tool_spec, input) do
    Sandbox.execute(tool_spec, input)
  end

  defp execute_tool(tool_spec, input) do
    try do
      tool_spec.execute.(input)
    rescue
      e -> {:error, {:execution_failed, Exception.message(e)}}
    end
  end
end

defmodule ToolInterface.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ToolInterface.Registry,
      ToolInterface.Audit
    ]

    opts = [strategy: :one_for_one, name: ToolInterface.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
