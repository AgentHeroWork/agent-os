defmodule AgentScheduler.Evaluator do
  @moduledoc """
  6-dimensional quality evaluation and reputation computation for agents.

  Implements the evaluation framework from the paper, measuring agent performance
  across six orthogonal dimensions:

  1. **Quality** (`q`) — Correctness and completeness of output
  2. **Adherence** (`a`) — Conformance to task specification and constraints
  3. **Speed** (`s`) — Execution time relative to SLA
  4. **Cost Efficiency** (`c`) — Token/resource usage relative to budget
  5. **Error Rate** (`e`) — Frequency of errors (inverted: 1 - error_rate)
  6. **Revision Count** (`r`) — Number of revision cycles needed (inverted)

  ## Composite Score

  The composite score is a weighted inner product of the 6 dimensions:

      score(v) = Σ w_i × v_i

  where `w` is the weight vector (sums to 1) and `v` is the evaluation vector.

  ## Reputation (EWMA)

  Agent reputation is computed as an exponentially-weighted moving average:

      R_t = α × s_t + (1 - α) × R_{t-1}

  where `α = 0.3` is the decay parameter. This gives recent performance more
  weight while maintaining stability. Theorem 4 in the paper proves convergence:
  if scores converge, reputation converges.

  ## Configuration

  Weights can be customized per evaluation context:

      Evaluator.evaluate("agent_1", scores, weights: %{
        quality: 0.35,     # Legal analysis prioritizes quality
        adherence: 0.25,
        speed: 0.05,       # Speed is less critical
        cost: 0.10,
        error_rate: 0.15,
        revision_count: 0.10
      })
  """

  use GenServer
  require Logger

  # -- Types --

  @type agent_id :: String.t()

  @type dimension :: :quality | :adherence | :speed | :cost | :error_rate | :revision_count

  @type scores :: %{dimension() => float()}

  @type weights :: %{dimension() => float()}

  @type evaluation_result :: %{
          agent_id: agent_id(),
          scores: scores(),
          composite: float(),
          reputation: float(),
          evaluation_count: non_neg_integer(),
          timestamp: integer()
        }

  @type t :: %__MODULE__{
          scores: %{agent_id() => [float()]},
          raw_scores: %{agent_id() => [scores()]},
          reputations: %{agent_id() => float()},
          weights: weights(),
          alpha: float(),
          evaluation_count: non_neg_integer()
        }

  defstruct scores: %{},
            raw_scores: %{},
            reputations: %{},
            weights: %{},
            alpha: 0.3,
            evaluation_count: 0

  @dimensions [:quality, :adherence, :speed, :cost, :error_rate, :revision_count]

  @default_weights %{
    quality: 0.25,
    adherence: 0.20,
    speed: 0.15,
    cost: 0.15,
    error_rate: 0.15,
    revision_count: 0.10
  }

  # -- Client API --

  @doc """
  Starts the evaluator GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Evaluates an agent's performance across the 6 quality dimensions.

  Scores should be in [0, 1] where higher is better. For error_rate and
  revision_count, the raw metric is inverted internally (1 - value).

  ## Parameters

    - `agent_id` — The agent being evaluated
    - `scores` — Map of dimension => score (float in [0, 1])
    - `opts` — Options:
      - `:weights` — Custom weight vector (must sum to 1)
      - `:invert` — List of dimensions to invert (default: `[:error_rate, :revision_count]`)

  ## Returns

    - `{:ok, evaluation_result}` with composite score and updated reputation

  ## Examples

      Evaluator.evaluate("agent_web_tester", %{
        quality: 0.87,
        adherence: 0.92,
        speed: 0.78,
        cost: 0.85,
        error_rate: 0.05,       # Will be inverted to 0.95
        revision_count: 0.12    # Will be inverted to 0.88
      })
      # => {:ok, %{composite: 0.877, reputation: 0.877, ...}}
  """
  @spec evaluate(agent_id(), scores(), keyword()) :: {:ok, evaluation_result()}
  def evaluate(agent_id, scores, opts \\ []) do
    GenServer.call(__MODULE__, {:evaluate, agent_id, scores, opts})
  end

  @doc """
  Returns the evaluation history and current reputation for an agent.
  """
  @spec get_scores(agent_id()) :: {:ok, map()} | {:error, :not_found}
  def get_scores(agent_id) do
    GenServer.call(__MODULE__, {:get_scores, agent_id})
  end

  @doc """
  Returns the current reputation for an agent.
  """
  @spec get_reputation(agent_id()) :: {:ok, float()} | {:error, :not_found}
  def get_reputation(agent_id) do
    GenServer.call(__MODULE__, {:get_reputation, agent_id})
  end

  @doc """
  Computes the weighted distance between two evaluation vectors.

  This is useful for comparing agent performance or finding agents
  with similar quality profiles.

      d_w(v, v') = sqrt(Σ w_i × (v_i - v'_i)²)
  """
  @spec distance(scores(), scores(), weights()) :: float()
  def distance(scores_a, scores_b, weights \\ @default_weights) do
    @dimensions
    |> Enum.map(fn dim ->
      w = Map.get(weights, dim, 0.0)
      a = Map.get(scores_a, dim, 0.0)
      b = Map.get(scores_b, dim, 0.0)
      w * (a - b) * (a - b)
    end)
    |> Enum.sum()
    |> :math.sqrt()
  end

  @doc """
  Returns a ranking of agents by reputation, highest first.
  """
  @spec rank_agents() :: [{agent_id(), float()}]
  def rank_agents do
    GenServer.call(__MODULE__, :rank_agents)
  end

  @doc """
  Returns the current weight configuration.
  """
  @spec get_weights() :: weights()
  def get_weights do
    GenServer.call(__MODULE__, :get_weights)
  end

  @doc """
  Updates the default weight vector.

  Weights must be non-negative and sum to 1.
  """
  @spec set_weights(weights()) :: :ok | {:error, :invalid_weights}
  def set_weights(weights) do
    GenServer.call(__MODULE__, {:set_weights, weights})
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    weights = Keyword.get(opts, :weights, @default_weights)
    alpha = Keyword.get(opts, :alpha, 0.3)

    state = %__MODULE__{
      weights: weights,
      alpha: alpha
    }

    Logger.info(
      "Evaluator started (alpha: #{alpha}, dimensions: #{inspect(@dimensions)})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate, agent_id, raw_scores, opts}, _from, state) do
    weights = Keyword.get(opts, :weights, state.weights)
    invert_dims = Keyword.get(opts, :invert, [:error_rate, :revision_count])

    # Normalize scores: invert specified dimensions
    normalized =
      Enum.into(@dimensions, %{}, fn dim ->
        raw_value = Map.get(raw_scores, dim, 0.0)

        value =
          if dim in invert_dims do
            1.0 - min(raw_value, 1.0)
          else
            min(raw_value, 1.0)
          end

        {dim, max(value, 0.0)}
      end)

    # Compute composite score (weighted inner product with ideal vector)
    composite = weighted_score(normalized, weights)

    # Update reputation (EWMA)
    current_reputation = Map.get(state.reputations, agent_id, composite)
    new_reputation = state.alpha * composite + (1.0 - state.alpha) * current_reputation

    # Store history
    new_state =
      state
      |> update_in([Access.key(:scores), Access.key(agent_id, [])], &[composite | &1])
      |> update_in([Access.key(:raw_scores), Access.key(agent_id, [])], &[normalized | &1])
      |> put_in([Access.key(:reputations), agent_id], new_reputation)
      |> Map.update!(:evaluation_count, &(&1 + 1))

    result = %{
      agent_id: agent_id,
      scores: normalized,
      composite: Float.round(composite, 4),
      reputation: Float.round(new_reputation, 4),
      evaluation_count: length(Map.get(new_state.scores, agent_id, [])),
      timestamp: System.monotonic_time(:millisecond)
    }

    Logger.info(
      "Agent #{agent_id} evaluated: composite=#{result.composite}, " <>
        "reputation=#{result.reputation} (eval ##{result.evaluation_count})"
    )

    emit_telemetry(:evaluation_completed, result)

    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call({:get_scores, agent_id}, _from, state) do
    case Map.get(state.scores, agent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      composite_history ->
        result = %{
          agent_id: agent_id,
          composite_history: Enum.reverse(composite_history),
          raw_history: Enum.reverse(Map.get(state.raw_scores, agent_id, [])),
          reputation: Map.get(state.reputations, agent_id, 0.0),
          evaluation_count: length(composite_history)
        }

        {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_call({:get_reputation, agent_id}, _from, state) do
    case Map.get(state.reputations, agent_id) do
      nil -> {:reply, {:error, :not_found}, state}
      rep -> {:reply, {:ok, Float.round(rep, 4)}, state}
    end
  end

  @impl true
  def handle_call(:rank_agents, _from, state) do
    ranking =
      state.reputations
      |> Enum.sort_by(fn {_id, rep} -> rep end, :desc)
      |> Enum.map(fn {id, rep} -> {id, Float.round(rep, 4)} end)

    {:reply, ranking, state}
  end

  @impl true
  def handle_call(:get_weights, _from, state) do
    {:reply, state.weights, state}
  end

  @impl true
  def handle_call({:set_weights, weights}, _from, state) do
    total = weights |> Map.values() |> Enum.sum()

    if abs(total - 1.0) < 0.001 and Enum.all?(Map.values(weights), &(&1 >= 0)) do
      {:reply, :ok, %{state | weights: weights}}
    else
      {:reply, {:error, :invalid_weights}, state}
    end
  end

  # -- Private Helpers --

  @spec weighted_score(scores(), weights()) :: float()
  defp weighted_score(scores, weights) do
    @dimensions
    |> Enum.map(fn dim ->
      Map.get(scores, dim, 0.0) * Map.get(weights, dim, 0.0)
    end)
    |> Enum.sum()
  end

  defp emit_telemetry(event, measurements) do
    :telemetry.execute(
      [:agent_scheduler, :evaluator, event],
      %{system_time: System.system_time()},
      measurements
    )
  rescue
    _ -> :ok
  end
end
