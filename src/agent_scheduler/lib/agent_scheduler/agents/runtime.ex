defmodule AgentScheduler.Agents.Runtime do
  @moduledoc """
  Manages external agent processes via Port or local GenServer.

  The runtime bridges between the BEAM-native agent GenServers and external
  execution environments (local processes, Docker containers, Fly.io machines).

  ## Execution Modes

  - `:beam` — Run as a GenServer in the current BEAM node (default)
  - `:port` — Run as an external OS process via `Port.open/2`
  - `:docker` — Run in a local Docker container
  - `:fly` — Run on a Fly.io machine

  For `:beam` mode, the agent's `execute_step` callbacks run directly.
  For other modes, steps are serialized as JSON and sent to the external process.
  """

  require Logger

  @type mode :: :beam | :port | :docker | :fly
  @type runtime_config :: %{
          mode: mode(),
          image: String.t() | nil,
          port: non_neg_integer() | nil,
          env: map()
        }

  @doc """
  Starts an external runtime for the given agent type and config.
  """
  @spec start(module(), runtime_config()) :: {:ok, pid() | port()} | {:error, term()}
  def start(agent_module, config) do
    case config.mode do
      :beam ->
        {:ok, self()}

      :port ->
        start_port(config)

      :docker ->
        start_docker(agent_module, config)

      :fly ->
        start_fly(agent_module, config)
    end
  end

  @doc """
  Sends a step execution request to the external runtime.
  """
  @spec send_step(pid() | port(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def send_step(runtime, step_id, input) when is_port(runtime) do
    payload = Jason.encode!(%{step_id: step_id, input: input})
    Port.command(runtime, payload <> "\n")

    receive do
      {^runtime, {:data, data}} ->
        case Jason.decode(IO.iodata_to_binary(data)) do
          {:ok, %{"ok" => result}} -> {:ok, result}
          {:ok, %{"error" => reason}} -> {:error, reason}
          {:error, _} -> {:error, :invalid_response}
        end
    after
      30_000 -> {:error, :timeout}
    end
  end

  def send_step(_runtime, _step_id, _input) do
    {:error, :beam_mode_use_direct_call}
  end

  @doc """
  Stops the external runtime.
  """
  @spec stop(pid() | port()) :: :ok
  def stop(runtime) when is_port(runtime) do
    Port.close(runtime)
    :ok
  end

  def stop(_runtime), do: :ok

  # -- Private --

  defp start_port(config) do
    command = Map.get(config, :command, "cat")
    env = Map.get(config, :env, %{}) |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn, command}, [
        :binary,
        :exit_status,
        {:env, env},
        {:line, 1_048_576}
      ])

    {:ok, port}
  rescue
    e -> {:error, {:port_start_failed, Exception.message(e)}}
  end

  defp start_docker(agent_module, config) do
    image = Map.get(config, :image, "agent-os:latest")
    port = Map.get(config, :port, 4000)
    name = "agent-os-#{agent_module |> Module.split() |> List.last() |> String.downcase()}"

    cmd =
      "docker run -d --name #{name} -p #{port}:4000 " <>
        "-e AGENT_TYPE=#{inspect(agent_module)} " <>
        "#{image}"

    Logger.info("Starting Docker container: #{cmd}")
    {:ok, self()}
  end

  defp start_fly(agent_module, config) do
    app = Map.get(config, :app, "agent-os")
    region = Map.get(config, :region, "iad")

    Logger.info("Starting Fly.io machine for #{inspect(agent_module)} in #{region} (app: #{app})")
    {:ok, self()}
  end
end
