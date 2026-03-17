defmodule AgentOS.CLI.Commands.Deploy do
  @moduledoc """
  Deployment commands: docker, fly.

  These commands manage deploying agent-os itself (not individual agents)
  to Docker or Fly.io.
  """

  alias AgentOS.CLI.Output

  @doc "Routes deploy subcommands to their handlers."
  def run(["docker"], opts) do
    deploy_docker(opts)
  end

  def run(["fly" | rest], opts) do
    deploy_fly(rest, opts)
  end

  def run(_, _opts) do
    Output.info("""
    Usage: agent-os deploy <target> [options]

    Targets:
      docker                       Build and run with Docker Compose
      fly [--region <region>] [--app <name>]   Deploy to Fly.io
    """)
  end

  # --- Docker deployment ---

  defp deploy_docker(_opts) do
    Output.info("Building Docker image...")

    case System.cmd("docker", ["build", "-t", "agent-os", "."], stderr_to_stdout: true) do
      {output, 0} ->
        Output.info(output)
        Output.info("Starting containers with docker-compose...")

        case System.cmd("docker-compose", ["up", "-d"], stderr_to_stdout: true) do
          {up_output, 0} ->
            Output.info(up_output)
            Output.success("Docker deployment complete. Checking health...")
            check_local_health()

          {up_output, code} ->
            Output.error("docker-compose up failed (exit #{code}):\n#{up_output}")
        end

      {output, code} ->
        Output.error("docker build failed (exit #{code}):\n#{output}")
    end
  end

  # --- Fly.io deployment ---

  defp deploy_fly(args, _opts) do
    fly_opts = parse_fly_opts(args)
    region = Map.get(fly_opts, :region, "iad")
    app = Map.get(fly_opts, :app, "agent-os")

    Output.info("Deploying to Fly.io (app: #{app}, region: #{region})...")

    fly_args = ["deploy", "--region", region, "--app", app]

    case System.cmd("fly", fly_args, stderr_to_stdout: true) do
      {output, 0} ->
        Output.info(output)
        Output.success("Fly.io deployment complete. Checking health...")
        check_fly_health(app)

      {output, code} ->
        Output.error("fly deploy failed (exit #{code}):\n#{output}")
    end
  end

  # --- Health checks ---

  defp check_local_health do
    health_opts = %{host: "http://localhost:4000", api_key: nil, json: false}

    case AgentOS.CLI.HttpClient.get("/api/v1/health", health_opts) do
      {:ok, _} -> Output.success("Local health check passed")
      {:error, reason} -> Output.error("Local health check failed: #{inspect(reason)}")
    end
  end

  defp check_fly_health(app) do
    health_opts = %{host: "https://#{app}.fly.dev", api_key: nil, json: false}

    case AgentOS.CLI.HttpClient.get("/api/v1/health", health_opts) do
      {:ok, _} -> Output.success("Fly.io health check passed (#{app}.fly.dev)")
      {:error, reason} -> Output.error("Fly.io health check failed: #{inspect(reason)}")
    end
  end

  # --- Option parser ---

  defp parse_fly_opts(args), do: parse_kv(args, %{})

  defp parse_kv([], acc), do: acc
  defp parse_kv(["--region", v | rest], acc), do: parse_kv(rest, Map.put(acc, :region, v))
  defp parse_kv(["--app", v | rest], acc), do: parse_kv(rest, Map.put(acc, :app, v))
  defp parse_kv([_ | rest], acc), do: parse_kv(rest, acc)
end
