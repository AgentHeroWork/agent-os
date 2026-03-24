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
  alias AgentScheduler.Evaluator

  @doc """
  Runs a multi-stage pipeline from a ContractSpec.

  Each stage runs in a separate microVM. Context flows between stages
  via the filesystem (orchestrator manages). Returns collected artifacts
  from all stages.
  """
  @spec run(ContractSpec.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run(%ContractSpec{} = contract, input, opts \\ %{}) do
    Logger.info("Pipeline: starting '#{contract.name}' (#{length(contract.stages)} stages)")

    with :ok <- validate_credentials(contract),
         :ok <- check_microsandbox() do
      execute_stages(contract, input, opts)
    end
  end

  defp execute_stages(contract, input, opts) do
    topic = Map.get(input, :topic, "research")
    scripts_dir = resolve_scripts_dir()
    run_id = "run_#{:erlang.unique_integer([:positive])}"
    pipeline_start = System.monotonic_time(:millisecond)

    initial_state = %{
      artifacts: %{},
      previous_output_dir: nil,
      run_id: run_id,
      topic: topic,
      last_proof: %{"all_passed" => true, "checks" => []}
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
            duration_ms = System.monotonic_time(:millisecond) - pipeline_start
            proof = final_state.last_proof
            Logger.info("Pipeline: '#{contract.name}' completed successfully")

            # Evaluate the pipeline run via the 6-dimensional Evaluator
            evaluate_pipeline_run(run_id, proof, duration_ms)

            # Broadcast pipeline completion via PubSub for SSE consumers
            broadcast_pipeline_complete(run_id)

            # Notify configured channels (Slack, Telegram, etc.)
            AgentOS.Notifications.Dispatcher.dispatch(:pipeline_complete, %{
              contract_name: contract.name,
              topic: topic,
              run_id: run_id,
              duration_ms: duration_ms,
              artifacts: artifacts,
              proof: proof
            })

            {:ok, Map.put(artifacts, :run_id, run_id)}

          {:retry, reason} ->
            Logger.warning("Pipeline: verification failed — #{reason}")
            broadcast_pipeline_error(run_id, {:verification_failed, reason})

            AgentOS.Notifications.Dispatcher.dispatch(:pipeline_failed, %{
              contract_name: contract.name,
              topic: topic,
              error: {:verification_failed, reason}
            })

            {:error, {:verification_failed, reason}}
        end

      {:error, _} = err ->
        broadcast_pipeline_error(run_id, err)

        AgentOS.Notifications.Dispatcher.dispatch(:pipeline_failed, %{
          contract_name: contract.name,
          topic: topic,
          error: err
        })

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

        # Broadcast stage completion via PubSub for SSE consumers
        broadcast_stage_complete(state.run_id, stage.name, proof)

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
          previous_output_dir: output_dir,
          last_proof: proof
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

  defp validate_credentials(contract) do
    missing = Enum.reject(contract.credentials, &AgentOS.Secrets.available?/1)

    case missing do
      [] -> :ok
      list ->
        Logger.error("Pipeline: missing credentials: #{inspect(list)}")
        {:error, {:missing_credentials, list}}
    end
  end

  defp check_microsandbox do
    case MicroVM.health() do
      :ok -> :ok
      {:error, reason} ->
        Logger.error("Pipeline: microsandbox not available — #{inspect(reason)}")
        {:error, {:microsandbox_not_running, reason}}
    end
  end

  defp build_env(stage, contract, opts) do
    base = %{"JOB_TOKEN" => "pipeline_#{:erlang.unique_integer([:positive])}"}

    # Inject credentials via Secrets backend
    base = inject_secret(base, contract, :github_token, "GH_TOKEN")
    base = inject_secret(base, contract, :vercel_token, "VERCEL_TOKEN")

    # Inject LLM model from contract or stage
    model = stage[:model] || contract.model
    base = if model, do: Map.put(base, "LLM_MODEL", model), else: base

    provider = stage[:provider] || contract.provider
    base = if provider, do: Map.put(base, "LLM_PROVIDER", to_string(provider)), else: base

    Map.merge(base, Map.get(opts, :env, %{}))
  end

  defp inject_secret(env, contract, cred_atom, env_var) do
    if cred_atom in contract.credentials do
      case AgentOS.Secrets.resolve(cred_atom) do
        {:ok, val} -> Map.put(env, env_var, val)
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

  defp evaluate_pipeline_run(run_id, proof, duration_ms) do
    scores = %{
      quality: compute_quality_score(proof),
      adherence: 1.0,
      speed: compute_speed_score(duration_ms),
      cost: 1.0,
      error_rate: compute_error_rate(proof),
      revision_count: 0
    }

    try do
      Evaluator.evaluate(run_id, scores)
    rescue
      _ -> Logger.debug("Pipeline: Evaluator not available for scoring run #{run_id}")
    catch
      :exit, _ -> Logger.debug("Pipeline: Evaluator not available for scoring run #{run_id}")
    end
  end

  defp compute_quality_score(proof) do
    checks = Map.get(proof, "checks", [])

    if checks == [] do
      0.8
    else
      passed = Enum.count(checks, &(Map.get(&1, "passed", true)))
      passed / max(length(checks), 1)
    end
  end

  defp compute_speed_score(duration_ms) do
    cond do
      duration_ms < 60_000 -> 1.0
      duration_ms < 300_000 -> 0.8
      true -> 0.5
    end
  end

  defp compute_error_rate(proof) do
    checks = Map.get(proof, "checks", [])

    if checks == [] do
      0.0
    else
      failed = Enum.count(checks, &(!Map.get(&1, "passed", true)))
      failed / max(length(checks), 1)
    end
  end

  # ── PubSub Broadcasting ──────────────────────────────────────────

  defp broadcast_stage_complete(run_id, stage_name, proof) do
    try do
      Phoenix.PubSub.broadcast(
        AgentOS.Web.PubSub,
        "pipeline:#{run_id}",
        {:stage_complete, stage_name, proof}
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp broadcast_pipeline_complete(run_id) do
    try do
      Phoenix.PubSub.broadcast(
        AgentOS.Web.PubSub,
        "pipeline:#{run_id}",
        {:pipeline_complete, run_id}
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp broadcast_pipeline_error(run_id, reason) do
    try do
      Phoenix.PubSub.broadcast(
        AgentOS.Web.PubSub,
        "pipeline:#{run_id}",
        {:pipeline_error, run_id, reason}
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
