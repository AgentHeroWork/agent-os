defmodule AgentOS.CLI.Commands.Job do
  @moduledoc "Job management commands: submit, status."

  alias AgentOS.CLI.{HttpClient, Output}

  @doc "Routes job subcommands to their handlers."
  def run(["submit" | rest], opts) do
    submit(rest, opts)
  end

  def run(["status", id], opts) do
    status(id, opts)
  end

  def run(_, _opts) do
    Output.info("""
    Usage: agent-os job <subcommand> [options]

    Subcommands:
      submit    --task <task> --input '<json>'
      status    <id>
    """)
  end

  # --- Subcommands ---

  defp submit(args, opts) do
    cmd_opts = parse_submit_opts(args)

    case cmd_opts[:task] do
      nil ->
        Output.error("--task is required for job submit")

      task ->
        input =
          case cmd_opts[:input] do
            nil ->
              %{}

            json_str ->
              case Jason.decode(json_str) do
                {:ok, parsed} -> parsed
                {:error, _} ->
                  Output.error("Invalid JSON for --input: #{json_str}")
                  System.halt(1)
              end
          end

        body = %{client_id: "cli", task: task, input: input}

        case HttpClient.post("/api/v1/jobs", body, opts) do
          {:ok, %{"id" => id}} ->
            if opts[:json] do
              Output.json(%{id: id, task: task})
            else
              Output.success("Job submitted: #{id}")
            end

          {:ok, response} ->
            id = Map.get(response, "job_id", "unknown")
            Output.success("Job submitted: #{id}")

          {:error, reason} ->
            Output.error("Failed to submit job: #{inspect(reason)}")
        end
    end
  end

  defp status(id, opts) do
    case HttpClient.get("/api/v1/jobs/#{id}", opts) do
      {:ok, body} ->
        if opts[:json] do
          Output.json(body)
        else
          headers = ["Field", "Value"]

          rows =
            Enum.map(body, fn {k, v} ->
              [to_string(k), to_string(v)]
            end)

          Output.table(headers, rows)
        end

      {:error, reason} ->
        Output.error("Failed to get job status: #{inspect(reason)}")
    end
  end

  # --- Option parser ---

  defp parse_submit_opts(args), do: parse_kv(args, %{})

  defp parse_kv([], acc), do: acc
  defp parse_kv(["--task", v | rest], acc), do: parse_kv(rest, Map.put(acc, :task, v))
  defp parse_kv(["--input", v | rest], acc), do: parse_kv(rest, Map.put(acc, :input, v))
  defp parse_kv([_ | rest], acc), do: parse_kv(rest, acc)
end
