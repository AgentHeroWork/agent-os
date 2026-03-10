defmodule PlannerEngine.Decomposer do
  @moduledoc """
  Job Decomposition — Functorial DAG-based task decomposition.

  Implements the decomposition functor Δ: Tasks → DAG, which maps each task to
  a directed acyclic graph of subtasks with dependency edges. The functor preserves
  job semantics: executing the decomposed subtasks in topological order is equivalent
  to executing the original task.

  ## Topological Sort with Parallel Levels

  The `topological_sort/1` function returns a list of execution levels, where each
  level contains subtasks that can execute in parallel. Transitions between levels
  are barrier synchronizations: all tasks in level Lᵢ must complete before any task
  in level Lᵢ₊₁ begins.

  The number of levels equals the length of the critical path (longest dependency
  chain), which is the theoretical minimum number of sequential steps.

  ## Functorial Properties

    * **Preserves identities:** decomposing the identity task yields the identity DAG
    * **Preserves composition:** Δ(g ∘ f) = Δ(g) ∘ Δ(f) for composable dependencies

  ## Integration with Inngest

  Each level maps to an Inngest step group. Subtasks within a level execute as
  parallel Inngest functions. The completion event of the final subtask in a level
  triggers the next level.
  """

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "A subtask within a decomposed job"
  @type subtask :: %{
          id: String.t(),
          parent_task_id: String.t(),
          description: String.t(),
          required_capabilities: [atom()],
          estimated_credits: non_neg_integer(),
          estimated_duration: non_neg_integer(),
          dependencies: [String.t()],
          status: :pending | :running | :completed | :failed | :skipped
        }

  @typedoc "A directed acyclic graph of subtasks"
  @type dag :: %{
          task_id: String.t(),
          subtasks: %{String.t() => subtask()},
          edges: [{String.t(), String.t()}]
        }

  @typedoc "A task to be decomposed"
  @type task :: %{
          id: String.t(),
          description: String.t(),
          required_capabilities: [atom()],
          budget_ceiling: non_neg_integer(),
          subtask_specs: [map()]
        }

  @typedoc "An execution level containing parallelizable subtasks"
  @type execution_level :: [String.t()]

  @typedoc "An execution schedule: ordered list of parallel levels"
  @type execution_schedule :: [execution_level()]

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Decomposes a task into a DAG of subtasks.

  Analyzes the task's subtask specifications and infers dependency edges.
  Validates that the resulting graph is acyclic.

  ## Parameters

    * `task` — A map with at least `:id`, `:description`, and `:subtask_specs`.
      Each subtask spec is a map with `:description`, `:required_capabilities`,
      `:estimated_credits`, `:estimated_duration`, and optionally `:depends_on` (list of indices).

  ## Returns

    * `{:ok, dag}` — Successfully decomposed into a valid DAG
    * `{:error, :cyclic_dependency}` — The dependency graph contains a cycle
    * `{:error, :empty_task}` — No subtask specs provided

  ## Example

      task = %{
        id: "task_42",
        description: "Full web app test suite",
        subtask_specs: [
          %{description: "E2E tests", required_capabilities: [:playwright],
            estimated_credits: 1000, estimated_duration: 60},
          %{description: "Load tests", required_capabilities: [:k6],
            estimated_credits: 800, estimated_duration: 45},
          %{description: "Generate report", required_capabilities: [:reporting],
            estimated_credits: 200, estimated_duration: 15, depends_on: [0, 1]}
        ]
      }
      {:ok, dag} = PlannerEngine.Decomposer.decompose(task)
  """
  @spec decompose(task()) :: {:ok, dag()} | {:error, :cyclic_dependency | :empty_task}
  def decompose(%{subtask_specs: []}), do: {:error, :empty_task}
  def decompose(%{subtask_specs: nil}), do: {:error, :empty_task}

  def decompose(%{id: task_id} = task) do
    specs = task.subtask_specs

    # Generate subtasks with unique IDs
    subtasks =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {spec, idx} ->
        id = "#{task_id}_sub_#{idx}"

        %{
          id: id,
          parent_task_id: task_id,
          description: spec.description,
          required_capabilities: Map.get(spec, :required_capabilities, []),
          estimated_credits: Map.get(spec, :estimated_credits, 0),
          estimated_duration: Map.get(spec, :estimated_duration, 0),
          dependencies: resolve_dependencies(task_id, Map.get(spec, :depends_on, []), idx),
          status: :pending
        }
      end)

    # Build edge list from dependencies
    edges =
      Enum.flat_map(subtasks, fn st ->
        Enum.map(st.dependencies, fn dep_id -> {dep_id, st.id} end)
      end)

    subtask_map = Map.new(subtasks, &{&1.id, &1})

    dag = %{
      task_id: task_id,
      subtasks: subtask_map,
      edges: edges
    }

    case validate_dag(dag) do
      :ok ->
        Logger.info(
          "[Decomposer] Decomposed task=#{task_id} into #{map_size(subtask_map)} subtasks " <>
            "with #{length(edges)} dependencies"
        )

        {:ok, dag}

      {:error, :cycle} ->
        {:error, :cyclic_dependency}
    end
  end

  @doc """
  Computes the topological sort of a DAG, returning execution levels.

  Each level contains subtask IDs that can execute in parallel. The levels
  are ordered such that all dependencies of level Lᵢ₊₁ are satisfied by
  levels L₀ through Lᵢ.

  ## Parameters

    * `dag` — A DAG produced by `decompose/1`

  ## Returns

    * A list of execution levels, each being a list of subtask IDs.

  ## Example

      {:ok, dag} = PlannerEngine.Decomposer.decompose(task)
      schedule = PlannerEngine.Decomposer.topological_sort(dag)
      # => [["task_42_sub_0", "task_42_sub_1"], ["task_42_sub_2"]]
  """
  @spec topological_sort(dag()) :: execution_schedule()
  def topological_sort(%{subtasks: subtasks, edges: edges}) do
    in_degrees = compute_in_degrees(subtasks, edges)

    # Find sources (no incoming edges)
    sources =
      for {id, 0} <- in_degrees, do: id

    build_levels(edges, sources, in_degrees, Map.keys(subtasks), [])
  end

  @doc """
  Returns the critical path length of a DAG (minimum sequential steps).

  This equals the number of execution levels from `topological_sort/1`.
  """
  @spec critical_path_length(dag()) :: non_neg_integer()
  def critical_path_length(dag) do
    dag |> topological_sort() |> length()
  end

  @doc """
  Computes the total estimated credits for all subtasks in a DAG.
  """
  @spec total_estimated_credits(dag()) :: non_neg_integer()
  def total_estimated_credits(%{subtasks: subtasks}) do
    subtasks
    |> Map.values()
    |> Enum.reduce(0, fn st, acc -> acc + st.estimated_credits end)
  end

  @doc """
  Computes the estimated duration considering parallel execution.

  For each level, takes the max duration among subtasks in that level.
  Total is the sum of per-level max durations.
  """
  @spec estimated_parallel_duration(dag()) :: non_neg_integer()
  def estimated_parallel_duration(%{subtasks: subtasks} = dag) do
    dag
    |> topological_sort()
    |> Enum.reduce(0, fn level, total ->
      level_max =
        level
        |> Enum.map(fn id -> Map.fetch!(subtasks, id).estimated_duration end)
        |> Enum.max(fn -> 0 end)

      total + level_max
    end)
  end

  @doc """
  Merges two DAGs by connecting the sinks of the first to the sources of the second.

  This implements the functorial composition: Δ(g ∘ f) = Δ(g) ∘ Δ(f).

  ## Parameters

    * `dag1` — The first DAG (executes first)
    * `dag2` — The second DAG (executes after dag1)

  ## Returns

    * `{:ok, merged_dag}` — DAGs merged with cross-edges
  """
  @spec compose(dag(), dag()) :: {:ok, dag()}
  def compose(%{task_id: id1} = dag1, %{task_id: id2} = dag2) do
    sinks1 = find_sinks(dag1)
    sources2 = find_sources(dag2)

    # Create cross-edges: every sink of dag1 connects to every source of dag2
    cross_edges =
      for s <- sinks1, t <- sources2, do: {s, t}

    merged = %{
      task_id: "#{id1}_then_#{id2}",
      subtasks: Map.merge(dag1.subtasks, dag2.subtasks),
      edges: dag1.edges ++ dag2.edges ++ cross_edges
    }

    {:ok, merged}
  end

  # ── Private Functions ──────────────────────────────────────────────────────

  @spec resolve_dependencies(String.t(), [non_neg_integer()], non_neg_integer()) :: [String.t()]
  defp resolve_dependencies(_task_id, [], _current_idx), do: []

  defp resolve_dependencies(task_id, dep_indices, current_idx) do
    dep_indices
    |> Enum.reject(&(&1 >= current_idx))
    |> Enum.map(fn idx -> "#{task_id}_sub_#{idx}" end)
  end

  @spec validate_dag(dag()) :: :ok | {:error, :cycle}
  defp validate_dag(%{subtasks: subtasks, edges: edges}) do
    # Kahn's algorithm: if topological sort consumes all nodes, no cycle exists
    in_degrees = compute_in_degrees(subtasks, edges)
    sources = for {id, 0} <- in_degrees, do: id
    all_ids = Map.keys(subtasks)

    processed = kahn_traverse(edges, sources, in_degrees, MapSet.new())

    if MapSet.size(processed) == length(all_ids) do
      :ok
    else
      {:error, :cycle}
    end
  end

  @spec kahn_traverse(
          [{String.t(), String.t()}],
          [String.t()],
          %{String.t() => non_neg_integer()},
          MapSet.t()
        ) :: MapSet.t()
  defp kahn_traverse(_edges, [], _degrees, processed), do: processed

  defp kahn_traverse(edges, current, degrees, processed) do
    new_processed = Enum.reduce(current, processed, &MapSet.put(&2, &1))

    {new_degrees, next} =
      Enum.reduce(current, {degrees, []}, fn node, {deg_acc, next_acc} ->
        outgoing = Enum.filter(edges, fn {from, _to} -> from == node end)

        Enum.reduce(outgoing, {deg_acc, next_acc}, fn {_from, to}, {d, n} ->
          new_d = Map.update!(d, to, &(&1 - 1))

          if new_d[to] == 0 and not MapSet.member?(new_processed, to) do
            {new_d, [to | n]}
          else
            {new_d, n}
          end
        end)
      end)

    kahn_traverse(edges, Enum.uniq(next), new_degrees, new_processed)
  end

  @spec compute_in_degrees(%{String.t() => subtask()}, [{String.t(), String.t()}]) ::
          %{String.t() => non_neg_integer()}
  defp compute_in_degrees(subtasks, edges) do
    # Initialize all nodes with in-degree 0
    base = Map.new(Map.keys(subtasks), &{&1, 0})

    # Count incoming edges
    Enum.reduce(edges, base, fn {_from, to}, acc ->
      Map.update(acc, to, 1, &(&1 + 1))
    end)
  end

  @spec build_levels(
          [{String.t(), String.t()}],
          [String.t()],
          %{String.t() => non_neg_integer()},
          [String.t()],
          execution_schedule()
        ) :: execution_schedule()
  defp build_levels(_edges, [], _degrees, _all_ids, levels) do
    Enum.reverse(levels)
  end

  defp build_levels(edges, current_level, degrees, all_ids, levels) do
    processed = List.flatten([current_level | levels])

    # Reduce in-degrees for successors
    new_degrees =
      Enum.reduce(current_level, degrees, fn id, acc ->
        edges
        |> Enum.filter(fn {from, _to} -> from == id end)
        |> Enum.reduce(acc, fn {_from, to}, inner_acc ->
          Map.update!(inner_acc, to, &(&1 - 1))
        end)
      end)

    # Find next level: nodes with in-degree 0 not yet processed
    next_level =
      all_ids
      |> Enum.filter(fn id ->
        Map.get(new_degrees, id, 0) == 0 and id not in processed and id not in current_level
      end)

    build_levels(edges, next_level, new_degrees, all_ids, [current_level | levels])
  end

  @spec find_sinks(dag()) :: [String.t()]
  defp find_sinks(%{subtasks: subtasks, edges: edges}) do
    sources_of_edges = MapSet.new(edges, fn {from, _to} -> from end)

    subtasks
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(sources_of_edges, &1))
  end

  @spec find_sources(dag()) :: [String.t()]
  defp find_sources(%{subtasks: subtasks, edges: edges}) do
    targets_of_edges = MapSet.new(edges, fn {_from, to} -> to end)

    subtasks
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(targets_of_edges, &1))
  end
end
