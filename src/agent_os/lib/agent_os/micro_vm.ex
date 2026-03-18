defmodule AgentOS.MicroVM do
  @moduledoc """
  Elixir client for microsandbox microVM execution.

  Wraps the `msb` CLI to create, run, and manage microVMs for agent execution.
  Each agent job runs inside an isolated microVM with its own kernel (libkrun/HVF).

  Uses `msb exe` for ephemeral one-shot execution:
  - Volume mounts for /context/ (read-only) and /shared/output/ (read-write)
  - Environment variables for credentials (JOB_TOKEN, GH_TOKEN)
  - Network access to host (LLM proxy at localhost:4000) via --scope any
  - Alpine base image with tools installed via apk at runtime

  All agents MUST run in microVMs. No fallback to BEAM execution.
  """

  require Logger

  @base_image "alpine:latest"
  @default_memory 512
  @default_cpus 1

  @doc """
  Checks if microsandbox server is running and available.
  Returns :ok or {:error, reason}. All agent execution requires this.
  """
  @spec health() :: :ok | {:error, term()}
  def health do
    case System.cmd("msb", ["server", "status"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "Total") do
          :ok
        else
          {:error, :unexpected_status_output}
        end

      {output, _} ->
        {:error, {:msb_server_not_running, String.trim(output)}}
    end
  rescue
    e -> {:error, {:msb_not_installed, Exception.message(e)}}
  end

  @doc """
  Runs a full agent job in a microVM with context and output mounts.

  1. Checks microsandbox health (fail fast if not running)
  2. Mounts context_dir as /context (read-only)
  3. Mounts output_dir as /shared/output (read-write)
  4. Injects env vars (JOB_TOKEN, GH_TOKEN, etc.)
  5. Executes the agent script
  6. Returns {:ok, output} or {:error, reason}

  The script is expected to read /context/*.md and write results to /shared/output/.
  """
  @spec run_agent(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def run_agent(script_path, context_dir, output_dir, opts \\ %{}) do
    case health() do
      :ok ->
        do_run(script_path, context_dir, output_dir, opts)

      {:error, reason} ->
        Logger.error("MicroVM: microsandbox not available — #{inspect(reason)}")
        {:error, {:microsandbox_not_running, reason}}
    end
  end

  defp do_run(script_path, context_dir, output_dir, opts) do
    image = Map.get(opts, :image, @base_image)
    timeout = Map.get(opts, :timeout, 300_000)

    args = build_exec_args(image, script_path, context_dir, output_dir, opts)

    Logger.info("MicroVM: executing #{Path.basename(script_path)} in #{image}")

    case System.cmd("msb", ["exe" | args], stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        Logger.info("MicroVM: execution completed (#{String.length(output)} chars output)")
        {:ok, output}

      {output, exit_code} ->
        Logger.error(
          "MicroVM: execution failed (exit #{exit_code}): #{String.slice(output, 0, 500)}"
        )

        {:error, {:vm_execution_failed, exit_code, output}}
    end
  end

  defp build_exec_args(image, script_path, context_dir, output_dir, opts) do
    memory = Map.get(opts, :memory, @default_memory)
    cpus = Map.get(opts, :cpus, @default_cpus)
    env = Map.get(opts, :env, %{})

    base = [
      image,
      "-v", "#{context_dir}:/context",
      "-v", "#{output_dir}:/shared/output",
      "--memory", to_string(memory),
      "--cpus", to_string(cpus),
      "--scope", "any"
    ]

    env_args = Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end)

    base ++ env_args ++ ["-e", script_path]
  end
end
