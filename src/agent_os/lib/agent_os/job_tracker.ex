defmodule AgentOS.JobTracker do
  @moduledoc """
  ETS-based job status tracker.

  Provides a lightweight registry for tracking job lifecycle states.
  Jobs are tracked from submission through completion or failure.
  """

  use GenServer

  @table :job_tracker

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc "Starts the JobTracker GenServer and creates the ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Tracks a new job with the given initial state."
  @spec track(String.t(), atom() | String.t()) :: true
  def track(job_id, initial_state) do
    :ets.insert(@table, {job_id, initial_state, DateTime.utc_now()})
  end

  @doc "Updates the state of an existing tracked job."
  @spec update(String.t(), atom() | String.t()) :: boolean()
  def update(job_id, state) do
    :ets.update_element(@table, job_id, {2, state})
  end

  @doc "Retrieves the current state of a tracked job."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(job_id) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, state, created_at}] ->
        {:ok, %{id: job_id, status: state, created_at: created_at}}

      [] ->
        {:error, :not_found}
    end
  end

  # ── Server Callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end
end
