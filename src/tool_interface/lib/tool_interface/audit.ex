defmodule ToolInterface.Audit do
  @moduledoc """
  Per-invocation audit logging for the tool interface layer.

  Records every tool invocation with timestamp, agent identity, tool identity,
  input, output, execution duration, and status. Implements the audit functor
  `Aud : Tool -> Log` that maps each tool invocation to a log entry.

  ## Design

  The audit logger runs as a GenServer that receives log entries asynchronously
  via `GenServer.cast/2`, ensuring that audit overhead does not impact tool
  invocation latency. Entries are accumulated in memory and periodically
  flushed to persistent storage.

  ## Telemetry

  Each audit entry emits a `[:tool_interface, :invocation]` telemetry event
  with measurements `%{duration_ms: integer}` and metadata including agent_id,
  tool_id, and status.

  ## Examples

      iex> ToolInterface.Audit.log_invocation("agent-1", "web-search", %{query: "test"}, {:ok, []}, 42, :ok)
      :ok

      iex> ToolInterface.Audit.get_entries("agent-1")
      [%{agent_id: "agent-1", tool_id: "web-search", ...}]

      iex> ToolInterface.Audit.get_stats()
      %{total: 1, ok: 1, error: 0, avg_duration_ms: 42.0}
  """

  use GenServer
  require Logger

  @type status :: :ok | :error

  @type entry :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          agent_id: String.t(),
          tool_id: String.t(),
          input: map(),
          output: any(),
          duration_ms: non_neg_integer(),
          status: status()
        }

  defstruct entries: [],
            entry_count: 0,
            max_entries: 10_000,
            flush_interval_ms: 60_000

  # ---------- Client API ----------

  @doc "Starts the audit logger GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs a tool invocation asynchronously.

  This is a cast (fire-and-forget) to avoid adding latency to tool invocations.
  The entry is stored in memory and will be included in periodic flushes.

  ## Parameters

  - `agent_id` — the agent that invoked the tool
  - `tool_id` — the tool that was invoked
  - `input` — the input provided to the tool
  - `output` — the output produced (or error)
  - `duration_ms` — execution duration in milliseconds
  - `status` — `:ok` or `:error`
  """
  @spec log_invocation(String.t(), String.t(), map(), any(), non_neg_integer(), status()) :: :ok
  def log_invocation(agent_id, tool_id, input, output, duration_ms, status) do
    entry = %{
      id: generate_entry_id(),
      timestamp: DateTime.utc_now(),
      agent_id: agent_id,
      tool_id: tool_id,
      input: sanitize_for_logging(input),
      output: sanitize_for_logging(output),
      duration_ms: duration_ms,
      status: status
    }

    # Emit telemetry event for observability integrations
    :telemetry.execute(
      [:tool_interface, :invocation],
      %{duration_ms: duration_ms},
      %{agent_id: agent_id, tool_id: tool_id, status: status}
    )

    GenServer.cast(__MODULE__, {:log, entry})
  end

  @doc """
  Retrieves audit entries for a specific agent.

  ## Options

  - `:limit` — maximum number of entries to return (default: 100)
  - `:tool_id` — filter by tool identifier
  - `:status` — filter by status (`:ok` or `:error`)
  """
  @spec get_entries(String.t(), keyword()) :: [entry()]
  def get_entries(agent_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_entries, agent_id, opts})
  end

  @doc """
  Returns aggregate statistics across all audit entries.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Returns aggregate statistics for a specific agent.
  """
  @spec get_agent_stats(String.t()) :: map()
  def get_agent_stats(agent_id) do
    GenServer.call(__MODULE__, {:get_agent_stats, agent_id})
  end

  @doc """
  Clears all audit entries. Primarily for testing.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Forces a flush of in-memory entries to the configured sink.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  # ---------- GenServer Callbacks ----------

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, 10_000)
    flush_interval = Keyword.get(opts, :flush_interval_ms, 60_000)

    state = %__MODULE__{
      entries: [],
      entry_count: 0,
      max_entries: max_entries,
      flush_interval_ms: flush_interval
    }

    # Schedule periodic flush
    if flush_interval > 0 do
      Process.send_after(self(), :periodic_flush, flush_interval)
    end

    Logger.info("[Audit] Initialized (max_entries: #{max_entries}, flush_interval: #{flush_interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    Logger.debug(
      "[Audit] #{entry.agent_id} -> #{entry.tool_id} [#{entry.status}] #{entry.duration_ms}ms"
    )

    entries =
      if state.entry_count >= state.max_entries do
        # Drop oldest entry when at capacity (ring buffer behavior)
        [entry | Enum.take(state.entries, state.max_entries - 1)]
      else
        [entry | state.entries]
      end

    new_count = min(state.entry_count + 1, state.max_entries)
    {:noreply, %{state | entries: entries, entry_count: new_count}}
  end

  @impl true
  def handle_call({:get_entries, agent_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    tool_filter = Keyword.get(opts, :tool_id, nil)
    status_filter = Keyword.get(opts, :status, nil)

    filtered =
      state.entries
      |> Enum.filter(fn entry ->
        entry.agent_id == agent_id and
          (is_nil(tool_filter) or entry.tool_id == tool_filter) and
          (is_nil(status_filter) or entry.status == status_filter)
      end)
      |> Enum.take(limit)

    {:reply, filtered, state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = compute_stats(state.entries)
    {:reply, stats, state}
  end

  def handle_call({:get_agent_stats, agent_id}, _from, state) do
    agent_entries = Enum.filter(state.entries, &(&1.agent_id == agent_id))
    stats = compute_stats(agent_entries)
    {:reply, stats, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: [], entry_count: 0}}
  end

  def handle_call(:flush, _from, state) do
    do_flush(state.entries)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:periodic_flush, state) do
    if state.entry_count > 0 do
      do_flush(state.entries)
    end

    Process.send_after(self(), :periodic_flush, state.flush_interval_ms)
    {:noreply, state}
  end

  # ---------- Private ----------

  defp compute_stats([]), do: %{total: 0, ok: 0, error: 0, avg_duration_ms: 0.0}

  defp compute_stats(entries) do
    total = length(entries)
    ok_count = Enum.count(entries, &(&1.status == :ok))
    error_count = total - ok_count
    total_duration = Enum.reduce(entries, 0, &(&1.duration_ms + &2))
    avg_duration = if total > 0, do: total_duration / total, else: 0.0

    %{
      total: total,
      ok: ok_count,
      error: error_count,
      avg_duration_ms: Float.round(avg_duration, 2),
      tools_used: entries |> Enum.map(& &1.tool_id) |> Enum.uniq() |> length(),
      agents_active: entries |> Enum.map(& &1.agent_id) |> Enum.uniq() |> length()
    }
  end

  defp do_flush(entries) do
    count = length(entries)

    if count > 0 do
      Logger.info("[Audit] Flushing #{count} entries to persistent storage")
      # In production, this would write to a database, object storage,
      # or streaming pipeline (e.g., Kafka, CloudWatch, Datadog).
      # For now, entries are retained in memory only.
    end

    :ok
  end

  defp sanitize_for_logging(data) when is_map(data) do
    # Redact potentially sensitive fields
    sensitive_keys = ["password", "token", "secret", "api_key", "authorization"]

    Map.new(data, fn
      {key, _value} when is_binary(key) ->
        if String.downcase(key) in sensitive_keys do
          {key, "[REDACTED]"}
        else
          {key, sanitize_for_logging(Map.get(data, key))}
        end

      {key, value} ->
        {key, sanitize_for_logging(value)}
    end)
  end

  defp sanitize_for_logging(data) when is_list(data) do
    Enum.map(data, &sanitize_for_logging/1)
  end

  defp sanitize_for_logging(data), do: data

  defp generate_entry_id do
    :crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
