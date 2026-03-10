defmodule ToolInterface.MCPClient do
  @moduledoc """
  Model Context Protocol (MCP) client for runtime tool discovery.

  Implements the MCP client that connects to external MCP servers via HTTP,
  discovers available tools, and registers them in the tool registry with
  proper namespacing (`"serverName__toolName"`).

  ## Protocol

  MCP servers expose tools through a JSON-RPC-like interface:

  1. **Initialize** — Establish a session with the server
  2. **List Tools** — Discover available tools and their JSON Schemas
  3. **Call Tool** — Invoke a specific tool with typed input
  4. **List Resources** — Discover available data resources

  ## Authentication

  MCP servers are authenticated via Bearer tokens, matching the Agent-Hero
  pattern with `StreamableHTTPClientTransport`.

  ## Parallel Discovery

  Multiple MCP servers can be discovered in parallel using `discover_all/1`,
  which mirrors Agent-Hero's `Promise.allSettled()` pattern for fault-tolerant
  parallel connection.

  ## Examples

      iex> ToolInterface.MCPClient.discover_and_register("my-server", "https://mcp.example.com", "token")
      :ok

      iex> servers = [
      ...>   %{name: "s1", url: "https://s1.example.com", token: "t1"},
      ...>   %{name: "s2", url: "https://s2.example.com", token: "t2"}
      ...> ]
      iex> ToolInterface.MCPClient.discover_all(servers)
      [{:ok, "s1", [...]}, {:error, "s2", :connection_refused}]
  """

  require Logger

  @discovery_timeout 30_000
  @invocation_timeout 60_000

  @type server_config :: %{
          name: String.t(),
          url: String.t(),
          token: String.t()
        }

  @type mcp_tool :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          execute: (map() -> {:ok, any()} | {:error, term()})
        }

  @doc """
  Discovers tools from a single MCP server and registers them in the registry.

  Connects to the server, lists available tools, wraps each tool with a
  remote invocation handler, and registers them with the appropriate
  namespace (`"serverName__toolName"`).

  ## Returns

  - `:ok` — tools were discovered and registered successfully
  - `{:error, reason}` — discovery or registration failed
  """
  @spec discover_and_register(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def discover_and_register(server_name, url, token) do
    Logger.info("[MCPClient] Discovering tools from #{server_name} at #{url}")

    with :ok <- validate_server_url(url),
         {:ok, session_id} <- initialize_session(url, token),
         {:ok, raw_tools} <- list_tools(url, token, session_id) do
      tools =
        Enum.map(raw_tools, fn raw_tool ->
          %{
            name: raw_tool["name"],
            description: raw_tool["description"] || "",
            input_schema: raw_tool["inputSchema"] || %{},
            execute: build_remote_executor(url, token, session_id, raw_tool["name"])
          }
        end)

      Logger.info("[MCPClient] Discovered #{length(tools)} tools from #{server_name}")
      ToolInterface.Registry.register_mcp(server_name, tools)
    end
  end

  @doc """
  Discovers tools from multiple MCP servers in parallel.

  Uses `Task.async_stream/3` for controlled concurrency with fault isolation.
  A failing server does not block discovery from other servers, mirroring
  Agent-Hero's `Promise.allSettled()` pattern.

  ## Options

  - `:max_concurrency` — maximum parallel connections (default: 10)
  - `:timeout` — per-server timeout in milliseconds (default: 30,000)

  ## Returns

  A list of `{:ok, server_name, tools}` or `{:error, server_name, reason}` tuples.
  """
  @spec discover_all([server_config()], keyword()) ::
          [{:ok, String.t(), [mcp_tool()]} | {:error, String.t(), term()}]
  def discover_all(servers, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, @discovery_timeout)

    servers
    |> Task.async_stream(
      fn server ->
        case discover_and_register(server.name, server.url, server.token) do
          :ok ->
            {:ok, server.name}

          {:error, reason} ->
            Logger.warning("[MCPClient] Failed to discover from #{server.name}: #{inspect(reason)}")
            {:error, server.name, reason}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, "unknown", :timeout}
      {:exit, reason} -> {:error, "unknown", {:task_failed, reason}}
    end)
  end

  @doc """
  Invokes a tool on a remote MCP server.

  Sends a `tools/call` JSON-RPC request to the server and returns
  the structured result.

  ## Returns

  - `{:ok, result}` — the tool returned a result
  - `{:error, reason}` — the invocation failed
  """
  @spec call_tool(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, any()} | {:error, term()}
  def call_tool(url, token, session_id, tool_name, input) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: generate_request_id(),
        method: "tools/call",
        params: %{
          name: tool_name,
          arguments: input
        }
      })

    case http_post(url, body, auth_headers(token, session_id), @invocation_timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => result}} ->
            {:ok, result}

          {:ok, %{"error" => %{"message" => msg}}} ->
            {:error, {:mcp_error, msg}}

          {:error, _} ->
            {:error, :invalid_response}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  # ---------- Private: MCP Protocol ----------

  defp initialize_session(url, token) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: generate_request_id(),
        method: "initialize",
        params: %{
          protocolVersion: "2024-11-05",
          capabilities: %{},
          clientInfo: %{
            name: "tool_interface",
            version: "0.1.0"
          }
        }
      })

    case http_post(url, body, auth_headers(token, nil), @discovery_timeout) do
      {:ok, %{status: 200, body: _response_body, headers: headers}} ->
        session_id = extract_session_id(headers)
        Logger.debug("[MCPClient] Session initialized: #{inspect(session_id)}")
        {:ok, session_id}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp list_tools(url, token, session_id) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: generate_request_id(),
        method: "tools/list",
        params: %{}
      })

    case http_post(url, body, auth_headers(token, session_id), @discovery_timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => %{"tools" => tools}}} ->
            {:ok, tools}

          {:ok, _} ->
            {:ok, []}

          {:error, _} ->
            {:error, :invalid_response}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp build_remote_executor(url, token, session_id, tool_name) do
    fn input ->
      call_tool(url, token, session_id, tool_name, input)
    end
  end

  defp validate_server_url(url) do
    ToolInterface.Sandbox.validate_url(url)
  end

  # ---------- Private: HTTP ----------

  defp http_post(url, body, headers, timeout) do
    # Uses Finch for production HTTP. Falls back to a stub for environments
    # without Finch started.
    try do
      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, ToolInterface.Finch, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: status, body: resp_body, headers: resp_headers}} ->
          {:ok, %{status: status, body: resp_body, headers: resp_headers}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      _ ->
        # Finch not started — return a stub error for development
        {:error, :http_client_not_available}
    end
  end

  defp auth_headers(token, session_id) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]

    if session_id do
      [{"mcp-session-id", session_id} | headers]
    else
      headers
    end
  end

  defp extract_session_id(headers) do
    Enum.find_value(headers, fn
      {"mcp-session-id", value} -> value
      {key, value} when is_binary(key) ->
        if String.downcase(key) == "mcp-session-id", do: value
      _ -> nil
    end)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
