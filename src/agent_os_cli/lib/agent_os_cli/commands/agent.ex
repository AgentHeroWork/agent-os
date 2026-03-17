defmodule AgentOS.CLI.Commands.Agent do
  @moduledoc "Agent management commands: create, list, start, stop, logs."

  alias AgentOS.CLI.{HttpClient, Output}

  @doc "Routes agent subcommands to their handlers."
  def run(["create" | rest], opts) do
    create(rest, opts)
  end

  def run(["list"], opts) do
    list(opts)
  end

  def run(["start", id | rest], opts) do
    start(id, rest, opts)
  end

  def run(["stop", id], opts) do
    stop(id, opts)
  end

  def run(["logs", id], opts) do
    logs(id, opts)
  end

  def run(_, _opts) do
    Output.info("""
    Usage: agent-os agent <subcommand> [options]

    Subcommands:
      create    --type <type> --name <name> [--oversight <level>]
      list
      start     <id> --job '<json>'
      stop      <id>
      logs      <id>
    """)
  end

  # --- Subcommands ---

  defp create(args, opts) do
    cmd_opts = parse_create_opts(args)

    case {cmd_opts[:type], cmd_opts[:name]} do
      {nil, _} ->
        Output.error("--type is required for agent create")

      {_, nil} ->
        Output.error("--name is required for agent create")

      {type, name} ->
        body = %{
          type: type,
          name: name,
          oversight: cmd_opts[:oversight] || "standard"
        }

        case HttpClient.post("/api/v1/agents", body, opts) do
          {:ok, %{"id" => id}} ->
            if opts[:json] do
              Output.json(%{id: id, type: type, name: name})
            else
              Output.success("Agent created: #{id}")
            end

          {:ok, response} ->
            id = Map.get(response, "agent_id", "unknown")
            Output.success("Agent created: #{id}")

          {:error, reason} ->
            Output.error("Failed to create agent: #{inspect(reason)}")
        end
    end
  end

  defp list(opts) do
    case HttpClient.get("/api/v1/agents", opts) do
      {:ok, %{"agents" => agents}} when is_list(agents) ->
        if opts[:json] do
          Output.json(agents)
        else
          headers = ["ID", "Type", "State", "Created"]

          rows =
            Enum.map(agents, fn a ->
              [
                Map.get(a, "id", ""),
                Map.get(a, "type", ""),
                Map.get(a, "state", ""),
                Map.get(a, "created_at", "")
              ]
            end)

          Output.table(headers, rows)
        end

      {:ok, body} ->
        Output.json(body)

      {:error, reason} ->
        Output.error("Failed to list agents: #{inspect(reason)}")
    end
  end

  defp start(id, rest, opts) do
    cmd_opts = parse_start_opts(rest)

    body =
      case cmd_opts[:job] do
        nil -> %{}
        json_str ->
          case Jason.decode(json_str) do
            {:ok, job_spec} -> %{job_spec: job_spec}
            {:error, _} ->
              Output.error("Invalid JSON for --job: #{json_str}")
              System.halt(1)
          end
      end

    case HttpClient.post("/api/v1/agents/#{id}/start", body, opts) do
      {:ok, _} -> Output.success("Agent #{id} started")
      {:error, reason} -> Output.error("Failed to start agent: #{inspect(reason)}")
    end
  end

  defp stop(id, opts) do
    case HttpClient.post("/api/v1/agents/#{id}/stop", %{}, opts) do
      {:ok, _} -> Output.success("Agent #{id} stopped")
      {:error, reason} -> Output.error("Failed to stop agent: #{inspect(reason)}")
    end
  end

  defp logs(id, opts) do
    case HttpClient.get("/api/v1/agents/#{id}/logs", opts) do
      {:ok, %{"logs" => entries}} when is_list(entries) ->
        if opts[:json] do
          Output.json(entries)
        else
          Enum.each(entries, fn entry ->
            ts = Map.get(entry, "timestamp", "")
            level = Map.get(entry, "level", "info")
            msg = Map.get(entry, "message", "")
            Output.info("[#{ts}] #{String.upcase(level)}: #{msg}")
          end)
        end

      {:ok, body} ->
        Output.json(body)

      {:error, reason} ->
        Output.error("Failed to get logs: #{inspect(reason)}")
    end
  end

  # --- Option parsers ---

  @doc false
  def parse_create_opts(args), do: parse_kv_opts(args, %{})

  @doc false
  def parse_start_opts(args), do: parse_kv_opts(args, %{})

  defp parse_kv_opts([], acc), do: acc
  defp parse_kv_opts(["--type", v | rest], acc), do: parse_kv_opts(rest, Map.put(acc, :type, v))
  defp parse_kv_opts(["--name", v | rest], acc), do: parse_kv_opts(rest, Map.put(acc, :name, v))

  defp parse_kv_opts(["--oversight", v | rest], acc),
    do: parse_kv_opts(rest, Map.put(acc, :oversight, v))

  defp parse_kv_opts(["--job", v | rest], acc), do: parse_kv_opts(rest, Map.put(acc, :job, v))
  defp parse_kv_opts([_ | rest], acc), do: parse_kv_opts(rest, acc)
end
