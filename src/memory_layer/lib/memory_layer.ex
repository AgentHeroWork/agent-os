defmodule MemoryLayer do
  @moduledoc """
  Memory Layer — Typed Filesystem for Persistent Agent Cognition.

  This is the main application module for the Memory Layer, Part III of the
  AI Operating System. It implements the categorical memory model where memory
  is a functor M: S → St from a schema category to a storage category.

  ## Architecture

  The application supervises the following components:

    * `MemoryLayer.Schema.Registry` — Runtime schema type resolution (GenServer)
    * `MemoryLayer.Storage` — Multi-backend storage router (GenServer)
    * `MemoryLayer.Graph` — Graph relationship manager (GenServer)

  ETS tables are created at startup for working memory (fast, in-process).
  Mnesia tables are initialized for persistent knowledge (durable, distributed).

  ## Usage

      # Create a typed memory instance
      {:ok, pid} = MemoryLayer.Memory.create(%MemoryLayer.Schema.FactData{
        assertion: "The login page requires a 60-second timeout",
        confidence: 0.95,
        source: "test_run_2026_03_10"
      })

      # Retrieve typed data
      {:ok, data} = MemoryLayer.Memory.data(pid)

      # Evolve with causal tracking
      {:ok, child_pid} = MemoryLayer.Memory.evolve(pid, %{confidence: 0.99}, :observation)

      # Search across backends
      {:ok, results} = MemoryLayer.Storage.search("login timeout", backend: :all)

      # Establish graph relationships
      :ok = MemoryLayer.Graph.link(parent_id, child_id, :evolved_into)
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    init_ets_tables()
    init_mnesia_tables()

    children = [
      {MemoryLayer.Schema.Registry, []},
      {MemoryLayer.Storage, []},
      {MemoryLayer.Graph, []}
    ]

    opts = [strategy: :one_for_one, name: MemoryLayer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Initialize ETS tables for working memory.

  Working memory provides microsecond access to the "hot" set of memories
  currently relevant to the agent's active task. Analogous to working memory
  in cognitive psychology.
  """
  @spec init_ets_tables() :: :ok
  defp init_ets_tables do
    # Working memory: fast read/write for active memories
    :ets.new(:memory_working, [:named_table, :set, :public, read_concurrency: true])
    # LRU tracking: {id, last_accessed_at} for eviction
    :ets.new(:memory_lru, [:named_table, :ordered_set, :public])
    :ok
  end

  @doc """
  Initialize Mnesia tables for persistent knowledge.

  Persistent knowledge survives process crashes and node restarts.
  Uses disc_copies for durability (writes to both RAM and disk).
  """
  @spec init_mnesia_tables() :: :ok
  defp init_mnesia_tables do
    # Ensure Mnesia schema exists on this node
    :mnesia.create_schema([node()])
    :mnesia.start()

    # Memories table: primary storage for all memory instances
    :mnesia.create_table(:memories, [
      {:attributes, [:id, :data]},
      {:disc_copies, [node()]},
      {:type, :set}
    ])

    # Versions table: causal version history
    :mnesia.create_table(:versions, [
      {:attributes, [:id, :entry]},
      {:disc_copies, [node()]},
      {:type, :bag}
    ])

    # Edges table: graph relationships between memories
    :mnesia.create_table(:edges, [
      {:attributes, [:key, :edge]},
      {:disc_copies, [node()]},
      {:type, :bag}
    ])

    # Wait for tables to be ready (up to 30 seconds)
    :mnesia.wait_for_tables([:memories, :versions, :edges], 30_000)

    :ok
  end
end
