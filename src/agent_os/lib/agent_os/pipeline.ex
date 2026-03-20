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

  alias AgentOS.{MicroVM, ContextBridge}
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
            {:ok, artifacts}

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
    Logger.info("Pipeline: running #{stage.name} in microVM...")

    case MicroVM.run_agent(script_path, context_dir, output_dir, %{env: env}) do
      {:ok, _output} ->
        Logger.info("Pipeline: #{stage.name} completed")

        # 6. Ingest output into ContextFS
        ContextBridge.ingest_output(
          %{id: stage_id, topic: state.topic},
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
        {:error, reason}
    end
  end

  defp resolve_scripts_dir do
    # Look for scripts relative to the project root
    candidates = [
      Path.join(File.cwd!(), "sandbox/scripts"),
      Path.expand("../../../../sandbox/scripts", __DIR__),
      "/Users/mlong/Documents/Development/agentherowork/agent-os/sandbox/scripts"
    ]

    Enum.find(candidates, List.last(candidates), &File.dir?/1)
  end

  defp resolve_script(stage, scripts_dir) do
    # Try stage-specific script, fall back to generic
    specific = Path.join(scripts_dir, "#{stage.name}.sh")

    if File.exists?(specific) do
      specific
    else
      Path.join(scripts_dir, "researcher.sh")
    end
  end

  defp build_env(_stage, contract, opts) do
    base = %{
      "JOB_TOKEN" => "pipeline_#{:erlang.unique_integer([:positive])}"
    }

    # Inject GitHub token if needed
    base =
      if :github_token in contract.credentials do
        case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
          {token, 0} -> Map.put(base, "GH_TOKEN", String.trim(token))
          _ -> base
        end
      else
        base
      end

    # Merge any custom env from opts
    Map.merge(base, Map.get(opts, :env, %{}))
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
