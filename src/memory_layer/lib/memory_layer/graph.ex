defmodule MemoryLayer.Graph do
  @moduledoc """
  Graph relationship manager for memory lineage.

  Implements the edge relation category E where objects are memory instances
  and morphisms are typed edges. The 2-categorical structure emerges when
  paths of edges are considered as 1-morphisms and equivalences between
  paths as 2-morphisms.

  ## Edge Relations

  Nine typed edge relations define the morphisms in E:

    * `:evolved_into` — Memory evolved into a new version
    * `:references` — Memory refers to another memory
    * `:supersedes` — Memory replaces an older one
    * `:contradicts` — Memory conflicts with another
    * `:supports` — Memory provides evidence for another
    * `:derived_from` — Memory was derived from one or more parents
    * `:part_of` — Memory is a component of a larger memory
    * `:triggers` — Memory causes creation of another
    * `:blocked_by` — Memory cannot proceed until another is resolved

  ## Graph Traversal

  Path queries compose edge relations: given a pattern [r1, r2, r3],
  traversal finds all memories reachable via paths matching the pattern.
  This is path composition in the edge relation category.

  ## Storage

  Edges are stored in the Mnesia `:edges` table (bag type, allowing
  multiple edges between the same pair of memories). The table key is
  the {from_id, to_id} pair for efficient forward traversal; reverse
  lookups use Mnesia's match_object.
  """

  use GenServer

  @typedoc "The nine edge relation types (morphisms in the edge category)."
  @type edge_relation ::
          :evolved_into
          | :references
          | :supersedes
          | :contradicts
          | :supports
          | :derived_from
          | :part_of
          | :triggers
          | :blocked_by

  @typedoc "A single edge in the memory graph."
  @type edge :: %{
          from: String.t(),
          to: String.t(),
          relation: edge_relation(),
          metadata: map(),
          created_at: DateTime.t()
        }

  @typedoc "Options for graph traversal."
  @type traverse_opts :: [
          max_depth: non_neg_integer(),
          direction: :forward | :reverse | :both,
          filter_relations: [edge_relation()]
        ]

  # ── Client API ─────────────────────────────────────────────

  @doc "Start the Graph manager GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a typed edge between two memories.

  Establishes a relationship (morphism) in the edge relation category.
  Metadata can carry additional context about the relationship.

  ## Examples

      :ok = Graph.link(parent_id, child_id, :evolved_into, %{reason: :observation})
      :ok = Graph.link(issue_id, decision_id, :derived_from)
  """
  @spec link(String.t(), String.t(), edge_relation(), map()) :: :ok | {:error, term()}
  def link(from_id, to_id, relation, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:link, from_id, to_id, relation, metadata})
  end

  @doc """
  Remove an edge between two memories.

  Soft-removes by adding a `deleted_at` timestamp to the edge metadata.
  """
  @spec unlink(String.t(), String.t(), edge_relation()) :: :ok | {:error, term()}
  def unlink(from_id, to_id, relation) do
    GenServer.call(__MODULE__, {:unlink, from_id, to_id, relation})
  end

  @doc """
  Get all edges originating from a memory.

  Returns all outgoing morphisms from the given memory in the edge category.
  """
  @spec edges_from(String.t()) :: [edge()]
  def edges_from(memory_id) do
    GenServer.call(__MODULE__, {:edges_from, memory_id})
  end

  @doc """
  Get all edges pointing to a memory.

  Returns all incoming morphisms to the given memory in the edge category.
  """
  @spec edges_to(String.t()) :: [edge()]
  def edges_to(memory_id) do
    GenServer.call(__MODULE__, {:edges_to, memory_id})
  end

  @doc """
  Get edges of a specific relation type from a memory.
  """
  @spec edges_of_type(String.t(), edge_relation()) :: [edge()]
  def edges_of_type(memory_id, relation) do
    GenServer.call(__MODULE__, {:edges_of_type, memory_id, relation})
  end

  @doc """
  Traverse the memory graph following a pattern of edge relations.

  Given a starting memory and a pattern [r1, r2, ...], finds all memories
  reachable by following edges matching the pattern in sequence. This is
  path composition in the edge relation category.

  ## Options

    * `:max_depth` — Maximum traversal depth (default: 10)
    * `:direction` — `:forward`, `:reverse`, or `:both` (default: `:forward`)
    * `:filter_relations` — Only follow edges of these types

  ## Examples

      # Find all memories that this one evolved into, transitively
      ids = Graph.traverse(root_id, [:evolved_into], max_depth: 5)

      # Find the full derivation chain
      ids = Graph.traverse(result_id, [:derived_from], direction: :reverse)
  """
  @spec traverse(String.t(), [edge_relation()], traverse_opts()) :: [String.t()]
  def traverse(start_id, pattern, opts \\ []) do
    GenServer.call(__MODULE__, {:traverse, start_id, pattern, opts})
  end

  @doc """
  Find all memories connected to a given memory within a depth limit.

  Returns the connected subgraph as a list of {memory_id, edge} tuples.
  This is the neighborhood in the edge relation category.
  """
  @spec neighborhood(String.t(), non_neg_integer()) :: [{String.t(), edge()}]
  def neighborhood(memory_id, max_depth \\ 2) do
    GenServer.call(__MODULE__, {:neighborhood, memory_id, max_depth})
  end

  @doc """
  Detect conflicts: find pairs of memories connected by :contradicts edges.

  Returns a list of {memory_a_id, memory_b_id} pairs with unresolved conflicts.
  """
  @spec conflicts(String.t()) :: [{String.t(), String.t()}]
  def conflicts(memory_id) do
    edges_of_type(memory_id, :contradicts)
    |> Enum.map(fn edge -> {edge.from, edge.to} end)
  end

  # ── GenServer Callbacks ────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, %{}}
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:link, from_id, to_id, relation, metadata}, _from, state) do
    edge = %{
      from: from_id,
      to: to_id,
      relation: relation,
      metadata: metadata,
      created_at: DateTime.utc_now()
    }

    result =
      :mnesia.transaction(fn ->
        :mnesia.write({:edges, {from_id, to_id}, edge})
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unlink, from_id, to_id, relation}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        objects = :mnesia.match_object({:edges, {from_id, to_id}, :_})

        Enum.each(objects, fn {:edges, key, edge} = record ->
          if edge.relation == relation do
            :mnesia.delete_object(record)

            # Write soft-deleted version
            deleted_edge = Map.put(edge, :metadata, Map.put(edge.metadata, :deleted_at, DateTime.utc_now()))
            :mnesia.write({:edges, key, deleted_edge})
          end
        end)
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:edges_from, memory_id}, _from, state) do
    edges = do_edges_from(memory_id)
    {:reply, edges, state}
  end

  @impl true
  def handle_call({:edges_to, memory_id}, _from, state) do
    edges = do_edges_to(memory_id)
    {:reply, edges, state}
  end

  @impl true
  def handle_call({:edges_of_type, memory_id, relation}, _from, state) do
    edges =
      do_edges_from(memory_id)
      |> Enum.filter(fn edge -> edge.relation == relation end)

    {:reply, edges, state}
  end

  @impl true
  def handle_call({:traverse, start_id, pattern, opts}, _from, state) do
    max_depth = Keyword.get(opts, :max_depth, 10)
    direction = Keyword.get(opts, :direction, :forward)
    filter = Keyword.get(opts, :filter_relations, pattern)

    results = do_traverse([start_id], filter, direction, max_depth, MapSet.new())

    # Remove the start node from results
    result_list = results |> MapSet.delete(start_id) |> MapSet.to_list()
    {:reply, result_list, state}
  end

  @impl true
  def handle_call({:neighborhood, memory_id, max_depth}, _from, state) do
    results = do_neighborhood(memory_id, max_depth, MapSet.new([memory_id]), [])
    {:reply, results, state}
  end

  # ── Private Traversal ─────────────────────────────────────

  @spec do_edges_from(String.t()) :: [edge()]
  defp do_edges_from(memory_id) do
    {:atomic, edges} =
      :mnesia.transaction(fn ->
        # Match all edges where from_id matches (key is {from, to})
        :mnesia.match_object({:edges, {memory_id, :_}, :_})
      end)

    edges
    |> Enum.map(fn {:edges, _key, edge} -> edge end)
    |> Enum.reject(fn edge -> Map.has_key?(edge.metadata, :deleted_at) end)
  end

  @spec do_edges_to(String.t()) :: [edge()]
  defp do_edges_to(memory_id) do
    {:atomic, edges} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({:edges, {:_, memory_id}, :_})
      end)

    edges
    |> Enum.map(fn {:edges, _key, edge} -> edge end)
    |> Enum.reject(fn edge -> Map.has_key?(edge.metadata, :deleted_at) end)
  end

  @spec do_traverse([String.t()], [edge_relation()], atom(), non_neg_integer(), MapSet.t()) ::
          MapSet.t()
  defp do_traverse(_, _, _, 0, visited), do: visited
  defp do_traverse([], _, _, _, visited), do: visited

  defp do_traverse(frontier, relations, direction, depth, visited) do
    new_visited = Enum.reduce(frontier, visited, &MapSet.put(&2, &1))

    next_frontier =
      Enum.flat_map(frontier, fn node_id ->
        edges =
          case direction do
            :forward -> do_edges_from(node_id)
            :reverse -> do_edges_to(node_id)
            :both -> do_edges_from(node_id) ++ do_edges_to(node_id)
          end

        edges
        |> Enum.filter(fn edge -> edge.relation in relations end)
        |> Enum.map(fn edge ->
          case direction do
            :forward -> edge.to
            :reverse -> edge.from
            :both -> if edge.from == node_id, do: edge.to, else: edge.from
          end
        end)
        |> Enum.reject(fn id -> MapSet.member?(new_visited, id) end)
      end)
      |> Enum.uniq()

    do_traverse(next_frontier, relations, direction, depth - 1, new_visited)
  end

  @spec do_neighborhood(String.t(), non_neg_integer(), MapSet.t(), [{String.t(), edge()}]) ::
          [{String.t(), edge()}]
  defp do_neighborhood(_, 0, _, acc), do: acc

  defp do_neighborhood(memory_id, depth, visited, acc) do
    outgoing = do_edges_from(memory_id)
    incoming = do_edges_to(memory_id)
    all_edges = outgoing ++ incoming

    new_entries =
      Enum.flat_map(all_edges, fn edge ->
        neighbor = if edge.from == memory_id, do: edge.to, else: edge.from

        if MapSet.member?(visited, neighbor) do
          []
        else
          [{neighbor, edge}]
        end
      end)

    new_ids = Enum.map(new_entries, fn {id, _} -> id end)
    new_visited = Enum.reduce(new_ids, visited, &MapSet.put(&2, &1))
    new_acc = acc ++ new_entries

    Enum.reduce(new_ids, new_acc, fn neighbor_id, current_acc ->
      do_neighborhood(neighbor_id, depth - 1, new_visited, current_acc)
    end)
  end
end
