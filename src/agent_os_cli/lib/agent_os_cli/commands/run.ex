defmodule AgentOS.CLI.Commands.Run do
  @moduledoc """
  Direct agent execution command.

  Runs an agent's full autonomous pipeline locally without requiring
  the web server. This is the primary way to execute agents:

      agent-os run openclaw --topic "particle physics at CERN"
      agent-os run nemoclaw --topic "privacy-preserving HEP analysis"
  """

  alias AgentOS.CLI.Output

  @doc "Routes the run command to the appropriate agent."
  def run([type | rest], opts) do
    cmd_opts = parse_run_opts(rest)

    case resolve_agent_module(type) do
      {:ok, agent_module, contract_module} ->
        execute(agent_module, contract_module, cmd_opts, opts)

      {:error, msg} ->
        Output.error(msg)
    end
  end

  def run([], _opts) do
    Output.info("""
    Usage: agent-os run <type> [options]

    Types:
      openclaw     Full-capability autonomous research agent
      nemoclaw     Privacy-guarded research agent with NeMo Guardrails

    Options:
      --topic <topic>         Research topic (required)
      --model <model>         LLM model (default: from env)
      --provider <provider>   LLM provider: openai, anthropic, ollama
      --output-dir <dir>      Output directory (default: /tmp/agent-os/artifacts)

    Examples:
      agent-os run openclaw --topic "Higgs boson decay channels"
      agent-os run nemoclaw --topic "differential privacy in particle physics"
    """)
  end

  defp execute(agent_module, contract_module, cmd_opts, global_opts) do
    topic = cmd_opts[:topic]

    if is_nil(topic) do
      Output.error("--topic is required for agent-os run")
    else
      do_execute(agent_module, contract_module, cmd_opts, global_opts)
    end
  end

  defp do_execute(agent_module, contract_module, cmd_opts, global_opts) do
    topic = cmd_opts[:topic]

    Output.info("Starting #{agent_module |> Module.split() |> List.last()} autonomous pipeline...")
    Output.info("Topic: #{topic}")

    # Build input with LLM config from opts and env
    input = build_input(cmd_opts)
    agent_id = "cli_#{:erlang.unique_integer([:positive])}"
    output_dir = cmd_opts[:output_dir] || "/tmp/agent-os/artifacts"

    # Build spec for AgentRunner
    spec = %AgentOS.AgentSpec{
      type: resolve_type_atom(agent_module),
      name: agent_id,
      oversight: :autonomous_escalation,
      metadata: %{agent_id: agent_id, output_dir: output_dir}
    }

    Output.info("Running with AgentRunner (contract: #{inspect(contract_module)})...")

    case AgentOS.AgentRunner.run(spec, contract_module, %{input: input}) do
      {:ok, artifacts} ->
        Output.success("Pipeline completed successfully!")
        Output.info("")

        if artifacts[:tex_path], do: Output.info("  .tex: #{artifacts[:tex_path]}")
        if artifacts[:pdf_path], do: Output.info("  .pdf: #{artifacts[:pdf_path]}")
        if artifacts[:repo_url], do: Output.info("  repo: #{artifacts[:repo_url]}")

        if global_opts[:json] do
          Output.json(artifacts)
        end

      {:error, reason} ->
        Output.error("Pipeline failed: #{inspect(reason)}")
    end
  end

  defp resolve_agent_module("openclaw") do
    {:ok, AgentScheduler.Agents.OpenClaw, AgentOS.Contracts.ResearchContract}
  end

  defp resolve_agent_module("nemoclaw") do
    {:ok, AgentScheduler.Agents.NemoClaw, AgentOS.Contracts.ResearchContract}
  end

  defp resolve_agent_module(type) do
    {:error, "Unknown agent type: #{type}. Available: openclaw, nemoclaw"}
  end

  defp resolve_type_atom(AgentScheduler.Agents.OpenClaw), do: :open_claw
  defp resolve_type_atom(AgentScheduler.Agents.NemoClaw), do: :nemo_claw
  defp resolve_type_atom(_), do: :generic

  defp build_input(cmd_opts) do
    input = %{topic: cmd_opts[:topic]}

    llm_config =
      %{}
      |> maybe_put(:model, cmd_opts[:model])
      |> maybe_put(:provider, parse_provider(cmd_opts[:provider]))

    if map_size(llm_config) > 0 do
      Map.put(input, :llm_config, llm_config)
    else
      input
    end
  end

  defp parse_provider(nil), do: nil
  defp parse_provider("openai"), do: :openai
  defp parse_provider("anthropic"), do: :anthropic
  defp parse_provider("ollama"), do: :ollama
  defp parse_provider(other), do: String.to_atom(other)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp parse_run_opts(args), do: parse_run_opts(args, %{})
  defp parse_run_opts([], acc), do: acc
  defp parse_run_opts(["--topic", v | rest], acc), do: parse_run_opts(rest, Map.put(acc, :topic, v))
  defp parse_run_opts(["--model", v | rest], acc), do: parse_run_opts(rest, Map.put(acc, :model, v))
  defp parse_run_opts(["--provider", v | rest], acc), do: parse_run_opts(rest, Map.put(acc, :provider, v))
  defp parse_run_opts(["--output-dir", v | rest], acc), do: parse_run_opts(rest, Map.put(acc, :output_dir, v))
  defp parse_run_opts([_ | rest], acc), do: parse_run_opts(rest, acc)
end
