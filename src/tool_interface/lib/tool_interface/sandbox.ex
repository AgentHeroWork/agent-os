defmodule ToolInterface.Sandbox do
  @moduledoc """
  Sandboxed tool execution via isolated BEAM processes.

  Implements the categorical sandbox subcategory by executing tool operations
  in isolated BEAM processes with their own heaps, enforcing:

  - **Process isolation**: Each execution runs in a spawned process with no access
    to the parent's state (BEAM heap isolation).
  - **Time bounding**: Executions are killed after a configurable timeout
    (default: 10 minutes, matching E2B sandbox behavior).
  - **Error containment**: Exceptions in sandbox processes are caught and returned
    as `{:error, reason}` tuples without crashing the parent.
  - **Resource cleanup**: Monitor-based cleanup ensures dead processes are reaped.

  ## Correspondence to E2B Sandboxes

  In the Agent-Hero production system, sandbox-tier tools execute in E2B ephemeral
  environments with 10-minute timeouts. This module mirrors that pattern using
  BEAM process isolation: each tool invocation spawns a monitored process that
  is terminated if it exceeds the timeout.

  ## Examples

      iex> tool_spec = %{execute: fn input -> {:ok, input["x"] * 2} end}
      iex> ToolInterface.Sandbox.execute(tool_spec, %{"x" => 21})
      {:ok, 42}

      iex> tool_spec = %{execute: fn _ -> Process.sleep(:infinity) end}
      iex> ToolInterface.Sandbox.execute(tool_spec, %{}, timeout: 100)
      {:error, :timeout}
  """

  require Logger

  @default_timeout 600_000  # 10 minutes in milliseconds (matching E2B)
  @max_timeout 1_800_000    # 30 minutes absolute maximum

  @type execute_opts :: [
          timeout: pos_integer(),
          max_memory_bytes: pos_integer() | nil,
          capture_output: boolean()
        ]

  @doc """
  Executes a tool operation in an isolated BEAM process.

  The tool's `execute` function is called in a spawned, monitored process.
  The parent waits for the result or kills the process on timeout.

  ## Options

  - `:timeout` — maximum execution time in milliseconds (default: 600,000 = 10 min)
  - `:capture_output` — whether to capture stdout/stderr (default: `false`)

  ## Returns

  - `{:ok, result}` — successful execution
  - `{:error, :timeout}` — execution exceeded the timeout
  - `{:error, {:sandbox_crashed, reason}}` — the sandbox process crashed
  - `{:error, {:execution_failed, message}}` — the tool raised an exception
  """
  @spec execute(map(), map(), execute_opts()) ::
          {:ok, any()} | {:error, term()}
  def execute(tool_spec, input, opts \\ []) do
    timeout = min(Keyword.get(opts, :timeout, @default_timeout), @max_timeout)
    parent = self()
    ref = make_ref()

    Logger.debug("[Sandbox] Starting isolated execution for #{Map.get(tool_spec, :name, "unknown")}")

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        # This process has its own heap — no shared mutable state with parent.
        # This is the BEAM's natural realisation of categorical sandboxing.
        result =
          try do
            case tool_spec.execute.(input) do
              {:ok, _} = ok -> ok
              {:error, _} = err -> err
              other -> {:ok, other}
            end
          rescue
            e ->
              {:error, {:execution_failed, Exception.message(e)}}
          catch
            :exit, reason ->
              {:error, {:sandbox_exit, reason}}

            :throw, value ->
              {:error, {:sandbox_throw, value}}
          end

        send(parent, {:sandbox_result, ref, result})
      end)

    receive do
      {:sandbox_result, ^ref, result} ->
        # Process completed normally; flush the monitor DOWN message
        Process.demonitor(monitor_ref, [:flush])
        Logger.debug("[Sandbox] Execution completed successfully (pid: #{inspect(pid)})")
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        Logger.warning("[Sandbox] Process crashed: #{inspect(reason)}")
        {:error, {:sandbox_crashed, reason}}
    after
      timeout ->
        # Kill the sandbox process and clean up
        Logger.warning("[Sandbox] Execution timed out after #{timeout}ms, killing process #{inspect(pid)}")
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          5_000 ->
            # Fallback: demonitor if DOWN never arrived
            Process.demonitor(monitor_ref, [:flush])
        end

        {:error, :timeout}
    end
  end

  @doc """
  Executes multiple tool operations in parallel sandboxes.

  Each tool is executed in its own isolated process. Results are collected
  using the `Task` module with `async_stream` for controlled concurrency.

  ## Options

  - `:timeout` — per-tool timeout in milliseconds (default: 600,000)
  - `:max_concurrency` — maximum parallel executions (default: 5)

  ## Returns

  A list of `{:ok, result}` or `{:error, reason}` tuples, one per tool.
  """
  @spec execute_parallel([{map(), map()}], keyword()) :: [{:ok, any()} | {:error, term()}]
  def execute_parallel(tool_input_pairs, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 5)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    tool_input_pairs
    |> Task.async_stream(
      fn {tool_spec, input} ->
        execute(tool_spec, input, timeout: timeout)
      end,
      max_concurrency: max_concurrency,
      timeout: timeout + 5_000,  # Task timeout slightly longer than sandbox timeout
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, :timeout}
      {:exit, reason} -> {:error, {:task_failed, reason}}
    end)
  end

  @doc """
  Validates that a URL is safe for sandbox access.

  Blocks localhost, loopback, link-local (169.254.x.x), and private network ranges.
  This prevents sandbox tools from accessing internal infrastructure.
  """
  @spec validate_url(String.t()) :: :ok | {:error, {:blocked_url, String.t()}}
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)
    host = uri.host || ""

    blocked_hosts = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    blocked_prefixes = [
      "169.254.", "10.", "192.168.",
      "172.16.", "172.17.", "172.18.", "172.19.",
      "172.20.", "172.21.", "172.22.", "172.23.",
      "172.24.", "172.25.", "172.26.", "172.27.",
      "172.28.", "172.29.", "172.30.", "172.31."
    ]

    cond do
      host in blocked_hosts ->
        {:error, {:blocked_url, "Host #{host} is blocked"}}

      Enum.any?(blocked_prefixes, &String.starts_with?(host, &1)) ->
        {:error, {:blocked_url, "IP range #{host} is blocked"}}

      true ->
        :ok
    end
  end

  def validate_url(_), do: {:error, {:blocked_url, "Invalid URL"}}
end
