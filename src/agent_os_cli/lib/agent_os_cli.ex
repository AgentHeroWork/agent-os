defmodule AgentOS.CLI do
  @moduledoc """
  Agent-OS CLI — manage agents locally or in the cloud.

  Usage:
    agent-os <command> <subcommand> [options]

  Commands:
    run <type>      Run an agent pipeline directly (openclaw, nemoclaw)
    agent create    Create a new agent
    agent list      List all agents
    agent start     Start an agent with a job
    agent stop      Stop a running agent
    agent logs      Show agent logs
    job submit      Submit a new job
    job status      Check job status
    memory search   Search memory
    deploy docker   Deploy with Docker
    deploy fly      Deploy to Fly.io
    version         Show CLI version
    health          Check API health

  Run options:
    --topic <topic>         Research topic
    --model <model>         LLM model (default: from env)
    --provider <provider>   LLM provider: openai, anthropic, ollama (default: auto)
    --output-dir <dir>      Output directory (default: /tmp/agent-os/artifacts)

  Global options:
    --target <local|fly>    Execution target (default: local, or AGENT_OS_TARGET env)
    --host <url>            API host (default: http://localhost:4000, or AGENT_OS_HOST env)
    --api-key <key>         API key (or AGENT_OS_API_KEY env)
    --json                  Output as JSON instead of table format
  """

  @doc """
  Escript entry point. Parses global options from argv, then routes
  to the appropriate command module.
  """
  def main(argv) do
    {global_opts, args} = parse_global_opts(argv)

    case args do
      ["run" | rest] -> AgentOS.CLI.Commands.Run.run(rest, global_opts)
      ["agent" | rest] -> AgentOS.CLI.Commands.Agent.run(rest, global_opts)
      ["job" | rest] -> AgentOS.CLI.Commands.Job.run(rest, global_opts)
      ["memory" | rest] -> AgentOS.CLI.Commands.Memory.run(rest, global_opts)
      ["deploy" | rest] -> AgentOS.CLI.Commands.Deploy.run(rest, global_opts)
      ["version"] -> AgentOS.CLI.Output.info("agent-os v0.1.0")
      ["health"] -> check_health(global_opts)
      _ -> print_usage()
    end
  end

  @doc """
  Parses global options (--target, --host, --api-key, --json) from argv.

  Returns `{opts_map, remaining_args}` where opts_map contains the extracted
  global flags and remaining_args is everything else.
  """
  def parse_global_opts(argv) do
    parse_global_opts(argv, %{}, [])
  end

  defp parse_global_opts([], opts, acc) do
    opts =
      opts
      |> Map.put_new_lazy(:target, fn ->
        System.get_env("AGENT_OS_TARGET", "local")
      end)
      |> Map.put_new_lazy(:host, fn ->
        System.get_env("AGENT_OS_HOST", "http://localhost:4000")
      end)
      |> Map.put_new_lazy(:api_key, fn ->
        System.get_env("AGENT_OS_API_KEY")
      end)
      |> Map.put_new(:json, Map.get(opts, :json, false))

    {opts, Enum.reverse(acc)}
  end

  defp parse_global_opts(["--target", value | rest], opts, acc) do
    parse_global_opts(rest, Map.put(opts, :target, value), acc)
  end

  defp parse_global_opts(["--host", value | rest], opts, acc) do
    parse_global_opts(rest, Map.put(opts, :host, value), acc)
  end

  defp parse_global_opts(["--api-key", value | rest], opts, acc) do
    parse_global_opts(rest, Map.put(opts, :api_key, value), acc)
  end

  defp parse_global_opts(["--json" | rest], opts, acc) do
    parse_global_opts(rest, Map.put(opts, :json, true), acc)
  end

  defp parse_global_opts([arg | rest], opts, acc) do
    parse_global_opts(rest, opts, [arg | acc])
  end

  defp check_health(opts) do
    case AgentOS.CLI.HttpClient.get("/api/v1/health", opts) do
      {:ok, body} ->
        status = Map.get(body, "status", "unknown")
        AgentOS.CLI.Output.success("API is healthy (status: #{status})")

      {:error, reason} ->
        AgentOS.CLI.Output.error("Health check failed: #{inspect(reason)}")
    end
  end

  defp print_usage do
    AgentOS.CLI.Output.info(@moduledoc)
  end
end
