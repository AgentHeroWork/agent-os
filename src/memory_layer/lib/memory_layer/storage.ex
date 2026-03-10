defmodule MemoryLayer.StorageBackend do
  @moduledoc """
  Behaviour (Protocol) defining the StorageBackend interface.

  In the categorical framework, each backend B is an object in the storage
  category St, and these callbacks define the morphisms (operations) available
  on each backend. The capability set Cap(B) is the subset of callbacks that
  a concrete backend implements.

  ## Required Callbacks

    * `save/1` — Persist a memory instance
    * `recall/1` — Retrieve by ID
    * `search/2` — Query with options
    * `delete/1` — Soft-delete by ID
    * `update/1` — Update existing memory
  """

  @callback save(memory :: map()) :: :ok | {:error, term()}
  @callback recall(id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  @callback search(query :: String.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback delete(id :: String.t()) :: :ok | {:error, term()}
  @callback update(memory :: map()) :: :ok | {:error, term()}
end

defmodule MemoryLayer.Storage do
  @moduledoc """
  Multi-backend StorageRouter — the coproduct of backend objects in St.

  Implements the storage router as a coproduct (disjoint union) of backends:

      Router = ∐ᵢ Bᵢ = B_ETS ⊔ B_Mnesia

  with injection morphisms ιᵢ: Bᵢ → Router and a universal property.

  ## Routing Policy

  The router dispatches operations based on a routing policy:

    * **Save**: Fan-out to all relevant backends (ETS for fast access, Mnesia for durability)
    * **Recall**: ETS first (fast path), fall back to Mnesia (durable path)
    * **Search**: Dispatches to the backend best suited for the query type
    * **Delete**: Soft-delete across all backends
    * **Update**: Update across all backends

  ## Capability Preservation (Theorem 7.4)

      Cap(Router) = ⋃ᵢ Cap(Bᵢ)

  The router exposes the union of all backend capabilities.

  ## Backends

  In this reference implementation:

    * **ETS** — In-process working memory (microsecond access, volatile)
    * **Mnesia** — Distributed persistent storage (ACID, disk-backed)

  Production deployments would add:

    * **ChromaDB** — Vector embeddings for semantic search
    * **FalkorDB** — Graph database for relationship traversal
    * **PostgreSQL** — Cloud-scale relational storage
  """

  use GenServer

  @behaviour MemoryLayer.StorageBackend

  @typedoc "Backend identifier for routing."
  @type backend :: :ets | :mnesia | :all | :exact | :semantic | :graph

  @typedoc "Search options."
  @type search_opts :: [
          backend: backend(),
          limit: non_neg_integer(),
          offset: non_neg_integer(),
          filter: map(),
          sort: atom(),
          include_deleted: boolean()
        ]

  # ── Client API / StorageBackend Implementation ─────────────

  @doc "Start the Storage router GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Persist a memory to all relevant backends (fan-out).

  Writes to ETS (working memory) and Mnesia (persistent knowledge).
  This ensures both fast access and durability.
  """
  @impl MemoryLayer.StorageBackend
  @spec save(map()) :: :ok | {:error, term()}
  def save(memory) do
    # ETS: fast working memory
    :ets.insert(:memory_working, {memory.id, memory})

    # Mnesia: durable persistent storage
    result =
      :mnesia.transaction(fn ->
        :mnesia.write({:memories, memory.id, memory})
      end)

    case result do
      {:atomic, _} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrieve a memory by ID.

  Checks ETS first (fast path). If not found, falls back to Mnesia
  (durable path) and promotes the memory to ETS for future access.
  """
  @impl MemoryLayer.StorageBackend
  @spec recall(String.t()) :: {:ok, map()} | {:error, :not_found}
  def recall(id) do
    case recall_from_ets(id) do
      {:ok, memory} ->
        {:ok, memory}

      {:error, :not_found} ->
        case recall_from_mnesia(id) do
          {:ok, memory} ->
            # Promote to ETS for fast future access
            :ets.insert(:memory_working, {id, memory})
            {:ok, memory}

          error ->
            error
        end
    end
  end

  @doc """
  Search for memories across backends.

  Dispatches to the appropriate backend based on the `:backend` option:

    * `:exact` or `:mnesia` — Exact match search in Mnesia
    * `:ets` — Search working memory only
    * `:semantic` — (placeholder) Would dispatch to ChromaDB
    * `:graph` — (placeholder) Would dispatch to FalkorDB
    * `:all` — Merge results from all backends
  """
  @impl MemoryLayer.StorageBackend
  @spec search(String.t(), search_opts()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    backend = Keyword.get(opts, :backend, :all)
    limit = Keyword.get(opts, :limit, 50)
    include_deleted = Keyword.get(opts, :include_deleted, false)
    filter = Keyword.get(opts, :filter, %{})

    results =
      case backend do
        :ets ->
          search_ets(query, filter)

        :exact ->
          search_mnesia(query, filter)

        :mnesia ->
          search_mnesia(query, filter)

        :semantic ->
          # Placeholder: would dispatch to ChromaDB for vector search
          # search_chroma(query, opts)
          search_mnesia(query, filter)

        :graph ->
          # Placeholder: would dispatch to FalkorDB for graph traversal
          # search_falkor(query, opts)
          search_mnesia(query, filter)

        :all ->
          merge_search_results([
            search_ets(query, filter),
            search_mnesia(query, filter)
          ])
      end

    filtered =
      results
      |> maybe_exclude_deleted(include_deleted)
      |> Enum.take(limit)

    {:ok, filtered}
  end

  @doc """
  Soft-delete a memory across all backends.

  Sets the `deleted_at` timestamp (tombstone pattern). The memory remains
  in storage for lineage preservation but is excluded from active queries.
  """
  @impl MemoryLayer.StorageBackend
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    case recall(id) do
      {:ok, memory} ->
        deleted_memory = Map.put(memory, :deleted_at, DateTime.utc_now())
        save(deleted_memory)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Update a memory across all backends.

  Writes the updated memory to both ETS and Mnesia.
  """
  @impl MemoryLayer.StorageBackend
  @spec update(map()) :: :ok | {:error, term()}
  def update(memory) do
    save(memory)
  end

  @doc """
  List all memories of a given schema type.
  """
  @spec list_by_type(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_by_type(schema_name, opts \\ []) do
    search("", Keyword.put(opts, :filter, %{schema_name: schema_name}))
  end

  @doc """
  Count memories in storage, optionally filtered by schema type.
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    case Keyword.get(opts, :schema_name) do
      nil ->
        :ets.info(:memory_working, :size)

      schema_name ->
        {:ok, results} = list_by_type(schema_name)
        length(results)
    end
  end

  @doc """
  Evict least-recently-used memories from ETS working memory.

  Keeps the most recent `keep` entries; demotes the rest to Mnesia-only.
  """
  @spec evict_lru(non_neg_integer()) :: non_neg_integer()
  def evict_lru(keep \\ 1000) do
    current_size = :ets.info(:memory_working, :size)

    if current_size > keep do
      # Get all LRU entries sorted by access time
      lru_entries =
        :ets.tab2list(:memory_lru)
        |> Enum.sort_by(fn {_id, time} -> time end)

      # Evict oldest entries
      to_evict = Enum.take(lru_entries, current_size - keep)

      Enum.each(to_evict, fn {id, _time} ->
        :ets.delete(:memory_working, id)
        :ets.delete(:memory_lru, id)
      end)

      length(to_evict)
    else
      0
    end
  end

  # ── GenServer Callbacks ────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, %{}}
  def init(_opts) do
    {:ok, %{}}
  end

  # ── Private Backend Operations ─────────────────────────────

  @spec recall_from_ets(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp recall_from_ets(id) do
    case :ets.lookup(:memory_working, id) do
      [{^id, memory}] -> {:ok, memory}
      [] -> {:error, :not_found}
    end
  end

  @spec recall_from_mnesia(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp recall_from_mnesia(id) do
    result =
      :mnesia.transaction(fn ->
        :mnesia.read({:memories, id})
      end)

    case result do
      {:atomic, [{:memories, ^id, memory}]} -> {:ok, memory}
      {:atomic, []} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @spec search_ets(String.t(), map()) :: [map()]
  defp search_ets(query, filter) do
    :ets.tab2list(:memory_working)
    |> Enum.map(fn {_id, memory} -> memory end)
    |> apply_filter(filter)
    |> apply_text_match(query)
  end

  @spec search_mnesia(String.t(), map()) :: [map()]
  defp search_mnesia(query, filter) do
    {:atomic, entries} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({:memories, :_, :_})
      end)

    entries
    |> Enum.map(fn {:memories, _id, memory} -> memory end)
    |> apply_filter(filter)
    |> apply_text_match(query)
  end

  @spec apply_filter([map()], map()) :: [map()]
  defp apply_filter(memories, filter) when filter == %{}, do: memories

  defp apply_filter(memories, filter) do
    Enum.filter(memories, fn memory ->
      Enum.all?(filter, fn {key, value} ->
        Map.get(memory, key) == value
      end)
    end)
  end

  @spec apply_text_match([map()], String.t()) :: [map()]
  defp apply_text_match(memories, ""), do: memories

  defp apply_text_match(memories, query) do
    query_lower = String.downcase(query)

    Enum.filter(memories, fn memory ->
      memory_text =
        memory
        |> inspect()
        |> String.downcase()

      String.contains?(memory_text, query_lower)
    end)
  end

  @spec maybe_exclude_deleted([map()], boolean()) :: [map()]
  defp maybe_exclude_deleted(memories, true), do: memories

  defp maybe_exclude_deleted(memories, false) do
    Enum.reject(memories, fn memory ->
      not is_nil(Map.get(memory, :deleted_at))
    end)
  end

  @spec merge_search_results([[map()]]) :: [map()]
  defp merge_search_results(result_sets) do
    result_sets
    |> List.flatten()
    |> Enum.uniq_by(fn memory -> Map.get(memory, :id) end)
  end
end
