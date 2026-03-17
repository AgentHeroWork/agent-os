defmodule AgentOS.CLI.Commands.Memory do
  @moduledoc "Memory commands: search, show."

  alias AgentOS.CLI.{HttpClient, Output}

  @doc "Routes memory subcommands to their handlers."
  def run(["search", query], opts) do
    search(query, opts)
  end

  def run(["show", id], opts) do
    show(id, opts)
  end

  def run(_, _opts) do
    Output.info("""
    Usage: agent-os memory <subcommand> [options]

    Subcommands:
      search    <query>
      show      <id>
    """)
  end

  # --- Subcommands ---

  defp search(query, opts) do
    encoded = URI.encode_www_form(query)

    case HttpClient.get("/api/v1/memory/search?q=#{encoded}", opts) do
      {:ok, %{"results" => results}} when is_list(results) ->
        if opts[:json] do
          Output.json(results)
        else
          headers = ["ID", "Type", "Content", "Score"]

          rows =
            Enum.map(results, fn r ->
              [
                Map.get(r, "id", ""),
                Map.get(r, "type", ""),
                truncate(Map.get(r, "content", ""), 60),
                to_string(Map.get(r, "score", ""))
              ]
            end)

          Output.table(headers, rows)
        end

      {:ok, body} ->
        Output.json(body)

      {:error, reason} ->
        Output.error("Failed to search memory: #{inspect(reason)}")
    end
  end

  defp show(id, opts) do
    case HttpClient.get("/api/v1/memory/#{id}", opts) do
      {:ok, body} ->
        if opts[:json] do
          Output.json(body)
        else
          headers = ["Field", "Value"]

          rows =
            Enum.map(body, fn {k, v} ->
              [to_string(k), truncate(to_string(v), 80)]
            end)

          Output.table(headers, rows)
        end

      {:error, reason} ->
        Output.error("Failed to get memory entry: #{inspect(reason)}")
    end
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."
end
