defmodule MemoryLayer.Version do
  @moduledoc """
  Versioned memory with causal change tracking.

  Implements the versioning functor V: Timeline → St that maps timestamps
  to storage states, and the VersionedMem[S] composite functor V ∘ M|_S.

  Each version entry records:

    * The memory ID and its parent's ID (lineage chain)
    * The version number (monotonically increasing)
    * The change reason (from the reason category R)
    * A vector clock for causal consistency across agents
    * A timestamp for temporal ordering

  ## Change Reasons (Reason Category)

  The four change reasons form a partially ordered set:

    * `:observation` — Base: new data was directly observed
    * `:inference` — Extends observation: a conclusion derived from observations
    * `:correction` — Subsumes observation: a previous version was wrong
    * `:decay` — Terminal: information is becoming stale or irrelevant

  The subsumption relation defines morphisms in the reason category:
  Correction → Observation, Inference → Observation, Decay → *.

  ## Vector Clocks

  In multi-agent settings, vector clocks track causal ordering. Each agent
  maintains a counter; on write, the writing agent increments its component.
  Two versions with incomparable vector clocks are concurrent (conflict).

  ## Implementation

  Version entries are stored in the Mnesia `:versions` table (bag type,
  allowing multiple entries per memory ID for full history).
  """

  @typedoc "The four change reasons in the reason category."
  @type change_reason :: :observation | :inference | :correction | :decay

  @typedoc "A version history entry."
  @type version_entry :: %{
          memory_id: String.t(),
          parent_id: String.t() | nil,
          version: non_neg_integer(),
          reason: change_reason(),
          vector_clock: vector_clock(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  @typedoc "A vector clock mapping agent/node identifiers to counters."
  @type vector_clock :: %{optional(atom() | String.t()) => non_neg_integer()}

  @typedoc "The result of comparing two vector clocks."
  @type clock_ordering :: :before | :after | :concurrent | :equal

  # ── Change Reason Operations ───────────────────────────────

  @doc """
  Test whether reason `a` subsumes reason `b` in the reason category.

  Subsumption defines morphisms: if `a` subsumes `b`, there is a morphism
  b → a in the reason category.

  ## Examples

      iex> Version.subsumes?(:correction, :observation)
      true

      iex> Version.subsumes?(:decay, :inference)
      true

      iex> Version.subsumes?(:observation, :correction)
      false
  """
  @spec subsumes?(change_reason(), change_reason()) :: boolean()
  def subsumes?(a, a), do: true
  def subsumes?(:correction, :observation), do: true
  def subsumes?(:inference, :observation), do: true
  def subsumes?(:decay, _), do: true
  def subsumes?(_, _), do: false

  @doc """
  Compute the join (least upper bound) of two change reasons.

  Used when merging version histories from concurrent updates.
  """
  @spec join_reasons(change_reason(), change_reason()) :: change_reason()
  def join_reasons(a, b) do
    cond do
      subsumes?(a, b) -> a
      subsumes?(b, a) -> b
      true -> :correction
    end
  end

  # ── Version Recording ──────────────────────────────────────

  @doc """
  Record a new version entry linking a child memory to its parent.

  Creates a version entry in the Mnesia `:versions` table within a
  transaction, ensuring atomicity. The vector clock is incremented
  for the current node.

  ## Parameters

    * `parent_id` — The ID of the parent memory (or nil for root)
    * `child_id` — The ID of the new version
    * `reason` — Why the memory changed
    * `parent_clock` — The parent's vector clock (inherited and incremented)
  """
  @spec record(String.t() | nil, String.t(), change_reason(), vector_clock()) :: :ok
  def record(parent_id, child_id, reason, parent_clock \\ %{}) do
    new_clock = increment_clock(parent_clock)
    version = next_version(parent_id)

    entry = %{
      memory_id: child_id,
      parent_id: parent_id,
      version: version,
      reason: reason,
      vector_clock: new_clock,
      timestamp: DateTime.utc_now(),
      metadata: %{}
    }

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({:versions, child_id, entry})
        :ok
      end)

    :ok
  end

  @doc """
  Retrieve the full version history of a memory.

  Returns all version entries for the given memory ID, sorted by
  timestamp (ascending). This traces the temporal functor:
  V(t0) → V(t1) → V(t2) → ...
  """
  @spec history(String.t()) :: [version_entry()]
  def history(memory_id) do
    {:atomic, entries} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({:versions, memory_id, :_})
      end)

    entries
    |> Enum.map(fn {:versions, _id, entry} -> entry end)
    |> Enum.sort_by(& &1.timestamp, DateTime)
  end

  @doc """
  Retrieve the full lineage chain from a memory back to its root.

  Follows the parent_id links recursively, building the complete
  path in the timeline category.
  """
  @spec lineage(String.t()) :: [version_entry()]
  def lineage(memory_id) do
    case history(memory_id) do
      [] ->
        []

      [entry | _] = entries ->
        case entry.parent_id do
          nil -> entries
          parent_id -> lineage(parent_id) ++ entries
        end
    end
  end

  @doc """
  Get the latest version number for a memory or its children.
  """
  @spec current_version(String.t()) :: non_neg_integer()
  def current_version(memory_id) do
    case history(memory_id) do
      [] -> 0
      entries -> entries |> Enum.map(& &1.version) |> Enum.max()
    end
  end

  # ── Vector Clock Operations ────────────────────────────────

  @doc """
  Compare two vector clocks to determine causal ordering.

  Returns:
    * `:before` — vc_a happened before vc_b
    * `:after` — vc_a happened after vc_b
    * `:concurrent` — vc_a and vc_b are causally independent (conflict!)
    * `:equal` — identical clocks
  """
  @spec compare_clocks(vector_clock(), vector_clock()) :: clock_ordering()
  def compare_clocks(vc_a, vc_b) when vc_a == vc_b, do: :equal

  def compare_clocks(vc_a, vc_b) do
    all_keys = Map.keys(vc_a) ++ Map.keys(vc_b) |> Enum.uniq()

    comparisons =
      Enum.map(all_keys, fn key ->
        a_val = Map.get(vc_a, key, 0)
        b_val = Map.get(vc_b, key, 0)

        cond do
          a_val < b_val -> :less
          a_val > b_val -> :greater
          true -> :equal
        end
      end)

    has_less = :less in comparisons
    has_greater = :greater in comparisons

    cond do
      has_less and has_greater -> :concurrent
      has_less -> :before
      has_greater -> :after
      true -> :equal
    end
  end

  @doc """
  Merge two vector clocks (component-wise maximum).

  Used when resolving conflicts: the merged clock dominates both inputs.
  """
  @spec merge_clocks(vector_clock(), vector_clock()) :: vector_clock()
  def merge_clocks(vc_a, vc_b) do
    Map.merge(vc_a, vc_b, fn _key, v1, v2 -> max(v1, v2) end)
  end

  @doc """
  Increment the vector clock for the current node.
  """
  @spec increment_clock(vector_clock()) :: vector_clock()
  def increment_clock(vc) do
    Map.update(vc, node(), 1, &(&1 + 1))
  end

  # ── Private Helpers ────────────────────────────────────────

  @spec next_version(String.t() | nil) :: non_neg_integer()
  defp next_version(nil), do: 1

  defp next_version(parent_id) do
    current_version(parent_id) + 1
  end
end
