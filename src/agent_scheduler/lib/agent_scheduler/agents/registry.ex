defmodule AgentScheduler.Agents.Registry do
  @moduledoc """
  GenServer that maps agent type atoms to modules implementing the AgentType behaviour.

  Provides registration, lookup, and listing of agent types. On init, auto-registers
  the built-in agent types (OpenClaw and NemoClaw).

  ## Examples

      iex> {:ok, pid} = AgentScheduler.Agents.Registry.start_link([])
      iex> AgentScheduler.Agents.Registry.lookup(:openclaw)
      {:ok, AgentScheduler.Agents.OpenClaw}

      iex> AgentScheduler.Agents.Registry.types()
      [:nemoclaw, :openclaw]
  """

  use GenServer

  require Logger

  @required_callbacks [:profile, :run_autonomous, :tool_requirements]

  # -- Client API --

  @doc """
  Starts the registry GenServer.

  ## Options

    * `:name` — GenServer name, defaults to `__MODULE__`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers an agent type atom to a module implementing the AgentType behaviour.

  Returns `:ok` on success or `{:error, reason}` if the module does not
  implement the required callbacks.
  """
  @spec register(atom(), module(), GenServer.server()) :: :ok | {:error, term()}
  def register(type_atom, module, server \\ __MODULE__) do
    GenServer.call(server, {:register, type_atom, module})
  end

  @doc """
  Removes a registered agent type.
  """
  @spec unregister(atom(), GenServer.server()) :: :ok
  def unregister(type_atom, server \\ __MODULE__) do
    GenServer.call(server, {:unregister, type_atom})
  end

  @doc """
  Looks up the module for a given agent type atom.

  Returns `{:ok, module}` or `{:error, :not_found}`.
  """
  @spec lookup(atom(), GenServer.server()) :: {:ok, module()} | {:error, :not_found}
  def lookup(type_atom, server \\ __MODULE__) do
    GenServer.call(server, {:lookup, type_atom})
  end

  @doc """
  Returns all registered agent types as a list of `{type_atom, module}` tuples.
  """
  @spec list(GenServer.server()) :: [{atom(), module()}]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Returns a sorted list of all registered type atoms.
  """
  @spec types(GenServer.server()) :: [atom()]
  def types(server \\ __MODULE__) do
    GenServer.call(server, :types)
  end

  # -- Server Callbacks --

  @impl true
  def init(_opts) do
    registry = %{}

    registry =
      registry
      |> do_register(:openclaw, AgentScheduler.Agents.OpenClaw)
      |> do_register(:nemoclaw, AgentScheduler.Agents.NemoClaw)

    Logger.info("AgentScheduler.Agents.Registry started with #{map_size(registry)} agent types")

    {:ok, registry}
  end

  @impl true
  def handle_call({:register, type_atom, module}, _from, registry) do
    case validate_behaviour(module) do
      :ok ->
        Logger.info("Registered agent type #{inspect(type_atom)} → #{inspect(module)}")
        {:reply, :ok, Map.put(registry, type_atom, module)}

      {:error, _} = error ->
        Logger.warning(
          "Failed to register #{inspect(type_atom)}: #{inspect(module)} does not implement AgentType"
        )

        {:reply, error, registry}
    end
  end

  @impl true
  def handle_call({:unregister, type_atom}, _from, registry) do
    Logger.info("Unregistered agent type #{inspect(type_atom)}")
    {:reply, :ok, Map.delete(registry, type_atom)}
  end

  @impl true
  def handle_call({:lookup, type_atom}, _from, registry) do
    case Map.fetch(registry, type_atom) do
      {:ok, module} -> {:reply, {:ok, module}, registry}
      :error -> {:reply, {:error, :not_found}, registry}
    end
  end

  @impl true
  def handle_call(:list, _from, registry) do
    {:reply, Map.to_list(registry), registry}
  end

  @impl true
  def handle_call(:types, _from, registry) do
    {:reply, registry |> Map.keys() |> Enum.sort(), registry}
  end

  # -- Private Helpers --

  defp do_register(registry, type_atom, module) do
    case validate_behaviour(module) do
      :ok ->
        Map.put(registry, type_atom, module)

      {:error, reason} ->
        Logger.warning(
          "Skipping auto-registration of #{inspect(type_atom)}: #{inspect(reason)}"
        )

        registry
    end
  end

  @spec validate_behaviour(module()) :: :ok | {:error, {:missing_callbacks, [atom()]}}
  defp validate_behaviour(module) do
    Code.ensure_loaded(module)

    missing =
      Enum.reject(@required_callbacks, fn callback ->
        function_exported?(module, callback, callback_arity(callback))
      end)

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_callbacks, missing}}
    end
  end

  defp callback_arity(:profile), do: 0
  defp callback_arity(:run_autonomous), do: 2
  defp callback_arity(:tool_requirements), do: 0
end
