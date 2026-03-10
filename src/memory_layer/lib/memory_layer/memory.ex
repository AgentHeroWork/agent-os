defmodule MemoryLayer.Memory do
  @moduledoc """
  Typed Memory GenServer — the Mem[S] generic wrapper.

  Implements the memory functor M: S → St for individual memory instances.
  Each memory is a GenServer process holding typed state, providing the
  core operations: create, wrap, data, update, evolve, and soft delete.

  ## Type Safety

  The generic parameter S (the schema struct) flows through all operations:

    * `create/1` validates the struct and initializes storage
    * `data/1` returns the typed payload
    * `update/2` applies validated changes
    * `evolve/3` creates a new version linked to the parent

  ## Storage Interaction

  On creation, memories are written to both ETS (working memory) and Mnesia
  (persistent knowledge) via the StorageRouter. The dual-layer architecture
  mirrors human cognitive architecture: ETS is working memory (fast, volatile),
  Mnesia is long-term memory (durable, queryable).

  ## Content Hashing

  Every memory instance receives a SHA-256 content hash computed from a
  canonical serialization of its data. This enables deduplication:
  two memories with identical content share the same hash.

  ## Soft Deletes

  Memories are never physically deleted. The `delete/1` operation sets the
  `deleted_at` timestamp (tombstone pattern). The active memory subcategory
  M_active is the full subcategory on memories with `deleted_at == nil`.
  """

  use GenServer

  alias MemoryLayer.{Version, Storage, Graph}

  @typedoc """
  The state held by each Memory GenServer process.
  Generic over the schema type — in practice, one of the 24 schema structs.
  """
  @type t :: %{
          id: String.t(),
          schema_name: String.t(),
          data: struct(),
          version: non_neg_integer(),
          content_hash: String.t(),
          vector_clock: map(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          deleted_at: DateTime.t() | nil
        }

  # ── Public API (Mem[S] Interface) ──────────────────────────

  @doc """
  Create a new typed memory instance from a schema struct.

  This is the `Mem[S].create(d: S) → Mem[S]` operation. The schema struct
  is validated (enforced keys must be present), a UUID is assigned, and the
  memory is persisted to both working memory (ETS) and persistent storage (Mnesia).

  ## Examples

      {:ok, pid} = Memory.create(%FactData{
        assertion: "Elixir compiles to BEAM bytecode",
        confidence: 1.0,
        source: "documentation"
      })
  """
  @spec create(struct()) :: {:ok, pid()} | {:error, term()}
  def create(schema_data) when is_struct(schema_data) do
    GenServer.start_link(__MODULE__, {:create, schema_data})
  end

  @doc """
  Wrap existing data with a fresh ID and timestamp.

  This is the `Mem[S].wrap(d: S) → Mem[S]` operation, used when importing
  data from external sources that already has content but needs memory
  layer metadata.
  """
  @spec wrap(struct(), keyword()) :: {:ok, pid()} | {:error, term()}
  def wrap(schema_data, opts \\ []) when is_struct(schema_data) do
    GenServer.start_link(__MODULE__, {:wrap, schema_data, opts})
  end

  @doc """
  Extract the typed payload from a memory process.

  Returns `{:ok, data}` where data is the original schema struct,
  or `{:error, :deleted}` if the memory has been soft-deleted.
  """
  @spec data(pid()) :: {:ok, struct()} | {:error, :deleted | term()}
  def data(pid) do
    GenServer.call(pid, :get_data)
  end

  @doc """
  Get the full memory state including metadata.

  Returns the complete state map with id, schema_name, version,
  content_hash, vector_clock, and timestamps.
  """
  @spec state(pid()) :: {:ok, t()} | {:error, term()}
  def state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Update fields on the memory's data struct.

  Applies the changes map to the underlying schema struct, increments
  the version number, recomputes the content hash, and persists.
  """
  @spec update(pid(), map()) :: :ok | {:error, term()}
  def update(pid, changes) when is_map(changes) do
    GenServer.call(pid, {:update, changes})
  end

  @doc """
  Evolve a memory into a new version with causal tracking.

  Creates a new Memory GenServer (child) linked to this one (parent)
  via a version record and graph edge. The change reason provides
  causal annotation: why did this memory change?

  ## Change Reasons

    * `:observation` — new data was observed
    * `:inference` — conclusion derived from existing data
    * `:correction` — previous version was wrong
    * `:decay` — information is becoming stale

  ## Examples

      {:ok, child_pid} = Memory.evolve(parent_pid, %{confidence: 0.99}, :observation)
  """
  @spec evolve(pid(), map(), Version.change_reason()) :: {:ok, pid()} | {:error, term()}
  def evolve(pid, changes, reason) do
    GenServer.call(pid, {:evolve, changes, reason})
  end

  @doc """
  Merge two memories into a new one.

  Creates a new memory combining data from both parents.
  Links the new memory to both parents via DERIVED_FROM edges.
  Used for resolving conflicts detected via vector clocks.
  """
  @spec merge(pid(), pid(), map()) :: {:ok, pid()} | {:error, term()}
  def merge(pid_a, pid_b, merged_data) do
    GenServer.call(pid_a, {:merge, pid_b, merged_data})
  end

  @doc """
  Soft-delete a memory (tombstone pattern).

  Sets the `deleted_at` timestamp. The memory remains in storage for
  lineage preservation but is excluded from active queries.
  """
  @spec delete(pid()) :: :ok | {:error, term()}
  def delete(pid) do
    GenServer.call(pid, :delete)
  end

  # ── GenServer Callbacks ────────────────────────────────────

  @impl true
  @spec init({:create, struct()} | {:wrap, struct(), keyword()}) :: {:ok, t()} | {:stop, term()}
  def init({:create, schema_data}) do
    case build_state(schema_data) do
      {:ok, state} ->
        persist(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def init({:wrap, schema_data, opts}) do
    case build_state(schema_data, opts) do
      {:ok, state} ->
        persist(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_data, _from, %{deleted_at: deleted} = state) when not is_nil(deleted) do
    {:reply, {:error, :deleted}, state}
  end

  def handle_call(:get_data, _from, state) do
    touch_lru(state.id)
    {:reply, {:ok, state.data}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    touch_lru(state.id)
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:update, changes}, _from, state) do
    updated_data = struct(state.data, Map.to_list(changes))
    new_hash = content_hash(updated_data)

    # Deduplication check: if content hasn't changed, skip
    if new_hash == state.content_hash do
      {:reply, :ok, state}
    else
      new_state = %{
        state
        | data: updated_data,
          version: state.version + 1,
          content_hash: new_hash,
          updated_at: DateTime.utc_now()
      }

      persist(new_state)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:evolve, changes, reason}, _from, state) do
    evolved_data = struct(state.data, Map.to_list(changes))

    case create(evolved_data) do
      {:ok, child_pid} ->
        {:ok, child_state} = GenServer.call(child_pid, :get_state)

        # Record version lineage
        Version.record(state.id, child_state.id, reason, state.vector_clock)

        # Establish graph edge
        Graph.link(state.id, child_state.id, :evolved_into, %{reason: reason})

        {:reply, {:ok, child_pid}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:merge, pid_b, merged_data}, _from, state_a) do
    case GenServer.call(pid_b, :get_state) do
      {:ok, state_b} ->
        case create(merged_data) do
          {:ok, merged_pid} ->
            {:ok, merged_state} = GenServer.call(merged_pid, :get_state)

            # Merge vector clocks: take component-wise max
            merged_clock = merge_vector_clocks(state_a.vector_clock, state_b.vector_clock)

            GenServer.call(merged_pid, {:set_vector_clock, merged_clock})

            # Link both parents to the merged child
            Graph.link(state_a.id, merged_state.id, :derived_from, %{operation: :merge})
            Graph.link(state_b.id, merged_state.id, :derived_from, %{operation: :merge})

            Version.record(state_a.id, merged_state.id, :correction, merged_clock)

            {:reply, {:ok, merged_pid}, state_a}

          {:error, reason} ->
            {:reply, {:error, reason}, state_a}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state_a}
    end
  end

  @impl true
  def handle_call(:delete, _from, state) do
    new_state = %{state | deleted_at: DateTime.utc_now()}
    persist(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_vector_clock, clock}, _from, state) do
    new_state = %{state | vector_clock: clock}
    persist(new_state)
    {:reply, :ok, new_state}
  end

  # ── Private Helpers ────────────────────────────────────────

  @spec build_state(struct(), keyword()) :: {:ok, t()} | {:error, term()}
  defp build_state(schema_data, opts \\ []) do
    id = Keyword.get(opts, :id) || generate_uuid()
    now = DateTime.utc_now()

    {:ok,
     %{
       id: id,
       schema_name: extract_schema_name(schema_data),
       data: schema_data,
       version: 1,
       content_hash: content_hash(schema_data),
       vector_clock: %{node() => 1},
       created_at: now,
       updated_at: now,
       deleted_at: nil
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec persist(t()) :: :ok
  defp persist(state) do
    # Write to ETS (working memory) — fast path
    :ets.insert(:memory_working, {state.id, state})

    # Write to Mnesia (persistent knowledge) — durable path
    Storage.save(state)

    # Update LRU tracking
    touch_lru(state.id)

    :ok
  end

  @spec touch_lru(String.t()) :: true
  defp touch_lru(id) do
    :ets.insert(:memory_lru, {id, System.monotonic_time()})
  end

  @doc false
  @spec content_hash(struct()) :: String.t()
  def content_hash(data) do
    data
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec extract_schema_name(struct()) :: String.t()
  defp extract_schema_name(data) do
    cond do
      Map.has_key?(data, :schema_name) -> to_string(Map.get(data, :schema_name))
      true -> data.__struct__ |> Module.split() |> List.last() |> Macro.underscore()
    end
  end

  @spec generate_uuid() :: String.t()
  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [
      Integer.to_string(a, 16),
      "-",
      Integer.to_string(b, 16),
      "-",
      Integer.to_string(c, 16),
      "-",
      Integer.to_string(d, 16),
      "-",
      Integer.to_string(e, 16)
    ]
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  @spec merge_vector_clocks(map(), map()) :: map()
  defp merge_vector_clocks(vc_a, vc_b) do
    Map.merge(vc_a, vc_b, fn _key, v1, v2 -> max(v1, v2) end)
  end
end
