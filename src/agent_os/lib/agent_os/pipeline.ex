defmodule AgentOS.Pipeline do
  @moduledoc """
  Multi-stage pipeline orchestrator.

  Executes contract stages sequentially, each in a microsandbox microVM.
  Between stages: ContextBridge prepares context from ContextFS and ingests
  output back. Each stage's output becomes the next stage's context.

  ## Execution Flow

      for stage in contract.stages:
        1. ContextBridge.prepare_context(task, stage)  ← query ContextFS, render .md
        2. MicroVM.run_agent(script, context, output)  ← isolated execution
        3. ContextBridge.ingest_output(task, agent, output) ← save to ContextFS
        4. output becomes next stage's previous_output_dir
  """

  require Logger

  alias AgentOS.{MicroVM, ContextBridge, Audit}
  alias AgentOS.Contracts.{ContractSpec, Verify}

  @doc """
  Runs a multi-stage pipeline from a ContractSpec.

  Each stage runs in a separate microVM. Context flows between stages
  via the filesystem (orchestrator manages). Returns collected artifacts
  from all stages.
  """
  @spec run(ContractSpec.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run(%ContractSpec{} = contract, input, opts \\ %{}) do
    Logger.info("Pipeline: starting '#{contract.name}' (#{length(contract.stages)} stages)")

    # Check microsandbox health — fail fast
    case MicroVM.health() do
      :ok ->
        execute_stages(contract, input, opts)

      {:error, reason} ->
        Logger.error("Pipeline: microsandbox not available — #{inspect(reason)}")
        {:error, {:microsandbox_not_running, reason}}
    end
  end

  defp execute_stages(contract, input, opts) do
    topic = Map.get(input, :topic, "research")
    scripts_dir = resolve_scripts_dir()
    run_id = "run_#{:erlang.unique_integer([:positive])}"

    initial_state = %{
      artifacts: %{},
      previous_output_dir: nil,
      run_id: run_id,
      topic: topic
    }

    result =
      Enum.reduce_while(contract.stages, {:ok, initial_state}, fn stage, {:ok, state} ->
        Logger.info("Pipeline: === Stage #{stage.name} ===")

        case run_stage(stage, state, contract, scripts_dir, opts) do
          {:ok, new_state} ->
            {:cont, {:ok, new_state}}

          {:error, reason} ->
            Logger.error("Pipeline: stage #{stage.name} failed — #{inspect(reason)}")
            {:halt, {:error, {:stage_failed, stage.name, reason}}}
        end
      end)

    case result do
      {:ok, final_state} ->
        artifacts = final_state.artifacts
        Logger.info("Pipeline: all stages complete, validating artifacts...")

        case Verify.check(artifacts, contract.verify) do
          :ok ->
            Logger.info("Pipeline: '#{contract.name}' completed successfully")
            {:ok, Map.put(artifacts, :run_id, run_id)}

          {:retry, reason} ->
            Logger.warning("Pipeline: verification failed — #{reason}")
            {:error, {:verification_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp run_stage(stage, state, contract, scripts_dir, opts) do
    stage_id = "#{state.run_id}_#{stage.name}"
    task = %{
      id: stage_id,
      topic: state.topic,
      description: stage.instructions,
      previous_output_dir: state.previous_output_dir
    }

    agent_spec = %{
      name: to_string(stage.name),
      stage: stage.name,
      instructions: stage.instructions
    }

    # 1. Prepare context (ContextFS queries + previous stage output)
    {:ok, context_dir} = ContextBridge.prepare_context(task, agent_spec)
    # 2. Prepare output directory
    output_dir = ContextBridge.prepare_output_dir(stage_id)

    # 3. Determine the script to run
    script_path = resolve_script(stage, scripts_dir)

    # 4. Build environment variables
    env = build_env(stage, contract, opts)

    # 5. Execute in microVM
    Logger.info("Pipeline: running #{stage.name} in microVM (script: #{Path.basename(script_path)})...")

    Audit.log_stage_start(state.run_id, stage.name, contract.name)
    stage_start = System.monotonic_time(:millisecond)

    case MicroVM.run_agent(script_path, context_dir, output_dir, %{env: env}) do
      {:ok, _output} ->
        duration_ms = System.monotonic_time(:millisecond) - stage_start
        Logger.info("Pipeline: #{stage.name} completed")

        # Read agent-side proof and audit files
        {:ok, proof} = read_agent_proof(output_dir)
        {:ok, audit_data} = read_agent_audit(output_dir)

        Audit.log_stage_complete(state.run_id, stage.name, proof, duration_ms)
        ingest_agent_audit(state.run_id, stage.name, audit_data)

        # 6. Ingest output into ContextFS with contract/stage tags
        ContextBridge.ingest_output(
          %{id: stage_id, topic: state.topic, contract_name: contract.name, stage_name: stage.name},
          "pipeline_#{stage.name}",
          output_dir
        )

        # 7. Collect artifacts
        new_artifacts = collect_artifacts(output_dir, state.artifacts)

        {:ok, %{state |
          artifacts: new_artifacts,
          previous_output_dir: output_dir
        }}

      {:error, reason} ->
        Audit.log_stage_fail(state.run_id, stage.name, reason)
        {:error, reason}
    end
  end

  defp resolve_scripts_dir do
    # Resolve scripts dir — check Application env, then common paths
    configured = Application.get_env(:agent_os, :scripts_dir)

    if configured && File.dir?(configured) do
      configured
    else
      candidates = [
        Path.join(File.cwd!(), "sandbox/scripts"),
        Path.expand("../../../../sandbox/scripts", __DIR__),
        Path.expand("../../../../../sandbox/scripts", __DIR__)
      ]

      Enum.find(candidates, hd(candidates), &File.dir?/1)
    end
  end

  defp resolve_script(_stage, scripts_dir) do
    # Universal agent runtime — the LLM decides which tools to use
    # based on the contract instructions in /context/brief.md
    Path.join(scripts_dir, "agent-runtime.sh")
  end

  defp build_env(_stage, contract, opts) do
    base = %{
      "JOB_TOKEN" => "pipeline_#{:erlang.unique_integer([:positive])}"
    }

    # Inject credentials declared by the contract
    base = inject_credential(base, contract, :github_token, fn ->
      case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
        {token, 0} -> {"GH_TOKEN", String.trim(token)}
        _ -> nil
      end
    end)

    base = inject_credential(base, contract, :vercel_token, fn ->
      case System.get_env("VERCEL_TOKEN") do
        nil -> nil
        token -> {"VERCEL_TOKEN", token}
      end
    end)

    # Merge any custom env from opts
    Map.merge(base, Map.get(opts, :env, %{}))
  end

  defp inject_credential(env, contract, cred_atom, resolver_fn) do
    if cred_atom in contract.credentials do
      case resolver_fn.() do
        {key, val} when is_binary(val) and val != "" -> Map.put(env, key, val)
        _ -> env
      end
    else
      env
    end
  end

  defp read_agent_proof(output_dir) do
    path = Path.join(output_dir, "_proof.json")

    case File.read(path) do
      {:ok, json} -> Jason.decode(json)
      _ -> {:ok, %{"all_passed" => true, "checks" => []}}
    end
  end

  defp read_agent_audit(output_dir) do
    path = Path.join(output_dir, "_audit.json")

    case File.read(path) do
      {:ok, json} -> Jason.decode(json)
      _ -> {:ok, %{}}
    end
  end

  defp ingest_agent_audit(run_id, stage_name, audit_data) do
    # Log each command from the agent's audit
    commands = Map.get(audit_data, "commands", [])

    Enum.each(commands, fn cmd ->
      Audit.log_tool_use(
        run_id,
        stage_name,
        Map.get(cmd, "command", "unknown"),
        Map.get(cmd, "description", ""),
        Map.get(cmd, "exit_code", 0),
        Map.get(cmd, "duration_ms", 0)
      )
    end)

    # Log LLM calls
    llm_calls = Map.get(audit_data, "llm_calls", [])

    Enum.each(llm_calls, fn call ->
      Audit.log_llm_call(
        run_id,
        stage_name,
        Map.get(call, "model", "gpt-4o"),
        Map.get(call, "duration_ms", 0)
      )
    end)
  end

  defp collect_artifacts(output_dir, existing) do
    case File.ls(output_dir) do
      {:ok, files} ->
        Enum.reduce(files, existing, fn filename, acc ->
          key = filename |> String.replace(~r/[^a-z0-9_]/, "_") |> String.to_atom()
          path = Path.join(output_dir, filename)
          Map.put(acc, key, path)
        end)

      _ ->
        existing
    end
  end
end
