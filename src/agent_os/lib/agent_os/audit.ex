defmodule AgentOS.Audit do
  @moduledoc """
  Structured audit logger for agent pipeline execution.

  Every command, LLM call, tool use, and stage transition is logged
  to a Mnesia table. Provides forensics for debugging and compliance.

  ## Mnesia Schema

  Table `:audit_log` (type `:bag`, keyed by `pipeline_id`):

      {id, pipeline_id, stage, event, data, timestamp}

  Events: `:stage_start`, `:stage_complete`, `:stage_fail`,
          `:tool_use`, `:llm_call`, `:contextfs_call`, `:proof_check`

  ## Design

  Writes are async (`GenServer.cast/2`) to avoid adding latency to the
  pipeline hot path. Reads are synchronous (`GenServer.call/3`) and use
  `:mnesia.match_object/1` for index-backed queries.
  """

  use GenServer
  require Logger

  @table :audit_log

  # ── Client API ────────────────────────────────────────────────────

  @doc "Starts the audit GenServer and ensures the Mnesia table exists."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Logs a generic event for a pipeline stage."
  @spec log_event(String.t(), atom(), atom(), map()) :: :ok
  def log_event(pipeline_id, stage, event, data) do
    GenServer.cast(__MODULE__, {:log, pipeline_id, stage, event, data})
  end

  @doc "Logs the start of a pipeline stage."
  @spec log_stage_start(String.t(), atom(), String.t()) :: :ok
  def log_stage_start(pipeline_id, stage, contract_name) do
    log_event(pipeline_id, stage, :stage_start, %{contract: contract_name})
  end

  @doc "Logs successful completion of a pipeline stage with proof and duration."
  @spec log_stage_complete(String.t(), atom(), map(), non_neg_integer()) :: :ok
  def log_stage_complete(pipeline_id, stage, proof, duration_ms) do
    log_event(pipeline_id, stage, :stage_complete, %{
      proof: proof,
      duration_ms: duration_ms
    })
  end

  @doc "Logs a stage failure with reason."
  @spec log_stage_fail(String.t(), atom(), term()) :: :ok
  def log_stage_fail(pipeline_id, stage, reason) do
    log_event(pipeline_id, stage, :stage_fail, %{reason: inspect(reason)})
  end

  @doc "Logs a tool/command invocation inside a stage."
  @spec log_tool_use(String.t(), atom(), String.t(), String.t(), integer(), non_neg_integer()) ::
          :ok
  def log_tool_use(pipeline_id, stage, tool, command, exit_code, duration_ms) do
    log_event(pipeline_id, stage, :tool_use, %{
      tool: tool,
      command: command,
      exit_code: exit_code,
      duration_ms: duration_ms
    })
  end

  @doc "Logs an LLM call made during a stage."
  @spec log_llm_call(String.t(), atom(), String.t(), non_neg_integer()) :: :ok
  def log_llm_call(pipeline_id, stage, model, duration_ms) do
    log_event(pipeline_id, stage, :llm_call, %{
      model: model,
      duration_ms: duration_ms
    })
  end

  @doc "Logs a ContextFS operation during a stage."
  @spec log_contextfs_call(String.t(), atom(), String.t(), non_neg_integer()) :: :ok
  def log_contextfs_call(pipeline_id, stage, operation, duration_ms) do
    log_event(pipeline_id, stage, :contextfs_call, %{
      operation: operation,
      duration_ms: duration_ms
    })
  end

  @doc """
  Returns the full audit trail for a pipeline run, ordered by timestamp.
  """
  @spec get_audit_trail(String.t()) :: {:ok, [map()]}
  def get_audit_trail(pipeline_id) do
    GenServer.call(__MODULE__, {:get_trail, pipeline_id})
  end

  @doc """
  Returns the proof record for a specific stage, or `{:error, :not_found}`.
  """
  @spec get_stage_proof(String.t(), atom() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_stage_proof(pipeline_id, stage) do
    GenServer.call(__MODULE__, {:get_proof, pipeline_id, stage})
  end

  # ── GenServer Callbacks ───────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_table()
    Logger.info("[Audit] Mnesia audit_log table ready")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:log, pipeline_id, stage, event, data}, state) do
    id = generate_id()
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    record = {
      @table,
      id,
      pipeline_id,
      stage,
      event,
      data,
      ts
    }

    :mnesia.transaction(fn -> :mnesia.write(record) end)

    Logger.debug("[Audit] #{pipeline_id}/#{stage} #{event}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_trail, pipeline_id}, _from, state) do
    entries = query_by_pipeline(pipeline_id)
    {:reply, {:ok, entries}, state}
  end

  def handle_call({:get_proof, pipeline_id, stage}, _from, state) do
    stage = if is_binary(stage), do: String.to_existing_atom(stage), else: stage

    entries = query_by_pipeline_and_stage(pipeline_id, stage)

    case Enum.find(entries, &(&1.event == :stage_complete)) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp ensure_table do
    # Ensure Mnesia schema directory exists for disc_copies
    :mnesia.create_schema([node()])
    :mnesia.start()

    case :mnesia.create_table(@table,
           attributes: [:id, :pipeline_id, :stage, :event, :data, :timestamp],
           type: :bag,
           index: [:pipeline_id, :stage]
         ) do
      {:atomic, :ok} ->
        Logger.info("[Audit] Created Mnesia table #{@table}")

      {:aborted, {:already_exists, @table}} ->
        Logger.debug("[Audit] Mnesia table #{@table} already exists")

      {:aborted, reason} ->
        Logger.warning("[Audit] Mnesia table creation: #{inspect(reason)}")
    end
  end

  defp query_by_pipeline(pipeline_id) do
    pattern = {@table, :_, pipeline_id, :_, :_, :_, :_}

    case :mnesia.transaction(fn -> :mnesia.match_object(pattern) end) do
      {:atomic, records} ->
        records
        |> Enum.map(&record_to_map/1)
        |> Enum.sort_by(& &1.timestamp)

      _ ->
        []
    end
  end

  defp query_by_pipeline_and_stage(pipeline_id, stage) do
    pattern = {@table, :_, pipeline_id, stage, :_, :_, :_}

    case :mnesia.transaction(fn -> :mnesia.match_object(pattern) end) do
      {:atomic, records} ->
        records
        |> Enum.map(&record_to_map/1)
        |> Enum.sort_by(& &1.timestamp)

      _ ->
        []
    end
  end

  defp record_to_map({@table, id, pipeline_id, stage, event, data, timestamp}) do
    %{
      id: id,
      pipeline_id: pipeline_id,
      stage: stage,
      event: event,
      data: data,
      timestamp: timestamp
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
