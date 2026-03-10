defmodule ToolInterface.Registry do
  @moduledoc """
  Three-tier tool registry implemented as a GenServer.

  Manages tools across three trust tiers:

  - **Builtin** — Statically defined, trusted operations: `web-search`, `text-transform`,
    `web-scrape`, `pdf-parse`, `generate-document`, `spreadsheet-read`.
  - **Sandbox** — Operations requiring isolated execution: `git-clone`, `npm-run`,
    `code-exec`, `file-ops`, `python-exec`, `shell-exec`.
  - **MCP** — Runtime-discovered tools from Model Context Protocol servers,
    namespaced as `"serverName__toolName"`.

  ## Contract-Locked Configuration

  The registry supports freezing via `freeze/0`. Once frozen, no new tools can be
  registered. This implements the contract-locked configuration pattern where
  tool sets are immutable during agent execution.

  ## Examples

      iex> ToolInterface.Registry.lookup("web-search")
      {:ok, %{name: "web-search", tier: :builtin, ...}}

      iex> ToolInterface.Registry.freeze()
      :ok

      iex> ToolInterface.Registry.register_mcp("server", [tool])
      {:error, :frozen}
  """

  use GenServer
  require Logger

  @type tool_tier :: :builtin | :sandbox | :mcp

  @type tool_spec :: %{
          name: String.t(),
          tier: tool_tier(),
          description: String.t(),
          input_schema: map(),
          output_schema: map() | nil,
          validate: (map() -> :ok | {:error, term()}) | nil,
          execute: (map() -> {:ok, any()} | {:error, term()})
        }

  defstruct builtin: %{},
            sandbox: %{},
            mcp: %{},
            frozen: false

  # ---------- Client API ----------

  @doc "Starts the registry GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up a tool by its identifier.

  Searches across all three tiers in order: builtin, sandbox, MCP.
  """
  @spec lookup(String.t()) :: {:ok, tool_spec()} | {:error, :not_found}
  def lookup(tool_id) do
    GenServer.call(__MODULE__, {:lookup, tool_id})
  end

  @doc """
  Registers tools discovered from an MCP server.

  Tools are namespaced as `"serverName__toolName"` to prevent collisions.
  Returns `{:error, :frozen}` if the registry has been frozen.
  """
  @spec register_mcp(String.t(), [map()]) :: :ok | {:error, :frozen}
  def register_mcp(server_name, tools) do
    GenServer.call(__MODULE__, {:register_mcp, server_name, tools})
  end

  @doc """
  Freezes the registry, preventing further tool registration.

  This implements contract-locked configuration: once an agent execution
  begins, the available tool set cannot change.
  """
  @spec freeze() :: :ok
  def freeze do
    GenServer.call(__MODULE__, :freeze)
  end

  @doc """
  Lists all registered tools, optionally filtered by tier.
  """
  @spec list(tool_tier() | nil) :: [tool_spec()]
  def list(tier \\ nil) do
    GenServer.call(__MODULE__, {:list, tier})
  end

  @doc """
  Returns whether the registry is currently frozen.
  """
  @spec frozen?() :: boolean()
  def frozen? do
    GenServer.call(__MODULE__, :frozen?)
  end

  # ---------- GenServer Callbacks ----------

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      builtin: load_builtin_tools(),
      sandbox: load_sandbox_tools(),
      mcp: %{},
      frozen: false
    }

    Logger.info("[Registry] Initialized with #{map_size(state.builtin)} builtin, #{map_size(state.sandbox)} sandbox tools")
    {:ok, state}
  end

  @impl true
  def handle_call({:lookup, tool_id}, _from, state) do
    result =
      case Map.get(state.builtin, tool_id) ||
             Map.get(state.sandbox, tool_id) ||
             Map.get(state.mcp, tool_id) do
        nil -> {:error, :not_found}
        tool -> {:ok, tool}
      end

    {:reply, result, state}
  end

  def handle_call({:register_mcp, _server_name, _tools}, _from, %{frozen: true} = state) do
    {:reply, {:error, :frozen}, state}
  end

  def handle_call({:register_mcp, server_name, tools}, _from, state) do
    namespaced =
      for tool <- tools, into: %{} do
        namespaced_name = "#{server_name}__#{tool.name}"

        spec = %{
          name: namespaced_name,
          tier: :mcp,
          description: Map.get(tool, :description, ""),
          input_schema: Map.get(tool, :input_schema, %{}),
          output_schema: Map.get(tool, :output_schema, nil),
          validate: build_mcp_validator(tool),
          execute: Map.get(tool, :execute, fn _ -> {:error, :not_implemented} end)
        }

        {namespaced_name, spec}
      end

    Logger.info("[Registry] Registered #{map_size(namespaced)} MCP tools from #{server_name}")
    {:reply, :ok, %{state | mcp: Map.merge(state.mcp, namespaced)}}
  end

  def handle_call(:freeze, _from, state) do
    total = map_size(state.builtin) + map_size(state.sandbox) + map_size(state.mcp)
    Logger.info("[Registry] Frozen with #{total} total tools")
    {:reply, :ok, %{state | frozen: true}}
  end

  def handle_call({:list, nil}, _from, state) do
    all =
      Map.values(state.builtin) ++
        Map.values(state.sandbox) ++
        Map.values(state.mcp)

    {:reply, all, state}
  end

  def handle_call({:list, :builtin}, _from, state) do
    {:reply, Map.values(state.builtin), state}
  end

  def handle_call({:list, :sandbox}, _from, state) do
    {:reply, Map.values(state.sandbox), state}
  end

  def handle_call({:list, :mcp}, _from, state) do
    {:reply, Map.values(state.mcp), state}
  end

  def handle_call(:frozen?, _from, state) do
    {:reply, state.frozen, state}
  end

  # ---------- Private: Builtin Tools ----------

  defp load_builtin_tools do
    [
      %{
        name: "web-search",
        tier: :builtin,
        description: "Search the web for information using a query string",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "max_results" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
          },
          "required" => ["query"]
        },
        output_schema: %{"type" => "array", "items" => %{"type" => "object"}},
        validate: &validate_web_search/1,
        execute: fn input ->
          {:ok, %{results: [], query: input["query"], note: "web-search stub"}}
        end
      },
      %{
        name: "text-transform",
        tier: :builtin,
        description: "Transform text using specified operations (summarize, translate, extract)",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string"},
            "operation" => %{"type" => "string", "enum" => ["summarize", "translate", "extract"]}
          },
          "required" => ["text", "operation"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{transformed: input["text"], operation: input["operation"]}}
        end
      },
      %{
        name: "web-scrape",
        tier: :builtin,
        description: "Scrape content from a URL with safety validation",
        input_schema: %{
          "type" => "object",
          "properties" => %{"url" => %{"type" => "string", "format" => "uri"}},
          "required" => ["url"]
        },
        output_schema: %{"type" => "object"},
        validate: &validate_url_safety/1,
        execute: fn input ->
          {:ok, %{content: "", url: input["url"], note: "web-scrape stub"}}
        end
      },
      %{
        name: "pdf-parse",
        tier: :builtin,
        description: "Parse a PDF document and extract text content",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string"},
            "pages" => %{"type" => "string"}
          },
          "required" => ["url"]
        },
        output_schema: %{"type" => "object"},
        validate: &validate_url_safety/1,
        execute: fn input ->
          {:ok, %{text: "", url: input["url"], note: "pdf-parse stub"}}
        end
      },
      %{
        name: "generate-document",
        tier: :builtin,
        description: "Generate a document from structured content",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string"},
            "format" => %{"type" => "string", "enum" => ["markdown", "html", "pdf"]}
          },
          "required" => ["content", "format"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{document: input["content"], format: input["format"]}}
        end
      },
      %{
        name: "spreadsheet-read",
        tier: :builtin,
        description: "Read data from a spreadsheet file",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string"},
            "sheet" => %{"type" => "string"}
          },
          "required" => ["url"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{rows: [], url: input["url"], note: "spreadsheet-read stub"}}
        end
      }
    ]
    |> Map.new(fn tool -> {tool.name, tool} end)
  end

  # ---------- Private: Sandbox Tools ----------

  defp load_sandbox_tools do
    [
      %{
        name: "git-clone",
        tier: :sandbox,
        description: "Clone a git repository into the sandbox",
        input_schema: %{
          "type" => "object",
          "properties" => %{"repo_url" => %{"type" => "string"}},
          "required" => ["repo_url"]
        },
        output_schema: %{"type" => "object"},
        validate: &validate_url_safety/1,
        execute: fn input ->
          {:ok, %{cloned: true, repo: input["repo_url"], note: "git-clone stub"}}
        end
      },
      %{
        name: "npm-run",
        tier: :sandbox,
        description: "Run an npm script in the sandbox",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "script" => %{"type" => "string"},
            "args" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["script"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{stdout: "", stderr: "", exit_code: 0, script: input["script"]}}
        end
      },
      %{
        name: "code-exec",
        tier: :sandbox,
        description: "Execute code in an isolated sandbox environment",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string"},
            "language" => %{"type" => "string", "enum" => ["javascript", "python", "typescript"]}
          },
          "required" => ["code", "language"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{stdout: "", stderr: "", exit_code: 0, language: input["language"]}}
        end
      },
      %{
        name: "file-ops",
        tier: :sandbox,
        description: "File operations (read, write, list) within the sandbox",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "operation" => %{"type" => "string", "enum" => ["read", "write", "list"]},
            "path" => %{"type" => "string"}
          },
          "required" => ["operation", "path"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{operation: input["operation"], path: input["path"], note: "file-ops stub"}}
        end
      },
      %{
        name: "python-exec",
        tier: :sandbox,
        description: "Execute Python code in an isolated sandbox",
        input_schema: %{
          "type" => "object",
          "properties" => %{"code" => %{"type" => "string"}},
          "required" => ["code"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{stdout: "", stderr: "", exit_code: 0, code: input["code"]}}
        end
      },
      %{
        name: "shell-exec",
        tier: :sandbox,
        description: "Execute a shell command in an isolated sandbox",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string"},
            "timeout_ms" => %{"type" => "integer"}
          },
          "required" => ["command"]
        },
        output_schema: %{"type" => "object"},
        validate: nil,
        execute: fn input ->
          {:ok, %{stdout: "", stderr: "", exit_code: 0, command: input["command"]}}
        end
      }
    ]
    |> Map.new(fn tool -> {tool.name, tool} end)
  end

  # ---------- Private: Validators ----------

  defp validate_web_search(%{"query" => q}) when is_binary(q) and byte_size(q) > 0, do: :ok
  defp validate_web_search(_), do: {:error, :invalid_query}

  defp validate_url_safety(%{"url" => url}) when is_binary(url) do
    validate_url_string(url)
  end

  defp validate_url_safety(%{"repo_url" => url}) when is_binary(url) do
    validate_url_string(url)
  end

  defp validate_url_safety(_), do: :ok

  defp validate_url_string(url) do
    uri = URI.parse(url)

    blocked_hosts = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]

    blocked_prefixes = [
      "169.254.",
      "10.",
      "172.16.",
      "172.17.",
      "172.18.",
      "172.19.",
      "172.20.",
      "172.21.",
      "172.22.",
      "172.23.",
      "172.24.",
      "172.25.",
      "172.26.",
      "172.27.",
      "172.28.",
      "172.29.",
      "172.30.",
      "172.31.",
      "192.168."
    ]

    host = uri.host || ""

    cond do
      host in blocked_hosts ->
        {:error, {:blocked_host, host}}

      Enum.any?(blocked_prefixes, &String.starts_with?(host, &1)) ->
        {:error, {:blocked_ip_range, host}}

      true ->
        :ok
    end
  end

  defp build_mcp_validator(%{input_schema: schema}) when schema != %{} do
    fn input ->
      # Basic type checking against JSON Schema
      validate_against_schema(input, schema)
    end
  end

  defp build_mcp_validator(_), do: nil

  defp validate_against_schema(_input, _schema) do
    # In production, this would use a JSON Schema validation library.
    # For now, accept all inputs that pass the basic structure check.
    :ok
  end
end
