defmodule PlannerEngine.Reputation do
  @moduledoc """
  Reputation Engine — 6-dimensional quality scoring and trust.

  Implements the reputation functor R: Agents → [0, 1] that maps each agent
  to a trust score based on historical quality performance. The reputation
  score is an exponentially-weighted inner product of 6-dimensional quality
  vectors, giving more weight to recent performance.

  ## Quality Dimensions

  Each completed job produces a quality vector q ∈ [0, 1]^6:

    1. **Accuracy** — Correctness of deliverables against requirements
    2. **Completeness** — Fraction of requirements addressed
    3. **Timeliness** — max(0, 1 - (actual - estimated) / deadline)
    4. **Communication** — Responsiveness and clarity (client-rated)
    5. **Efficiency** — 1 - (actual_credits - estimated_credits) / budget_ceiling
    6. **Innovation** — Exceeding requirements or novel approaches

  ## Reputation Formula

      R(α) = Σᵢ λ^(N-i) ⟨w, qᵢ⟩ / Σᵢ λ^(N-i)

  where w is the weight vector (default: uniform 1/6 each), λ is the decay
  factor (default: 0.95), and N is the number of completed jobs.

  ## Trust Score

  The trust score incorporates reputation, anti-gaming signals, and a seasoning
  factor requiring a minimum number of jobs:

      T(α) = R(α) × (1 - γ(α)) × min(1, N(α) / N_min)

  ## Anti-Gaming

  Five anomaly detectors identify suspected gaming:

    1. Self-dealing (shared wallet/IP)
    2. Score inflation (suspiciously low variance)
    3. Rapid cycling (too-fast completions with perfect scores)
    4. Collusion rings (clique detection in transaction graph)
    5. Reputation laundering (new identity after negative history)
  """

  use GenServer

  require Logger

  # ── Constants ──────────────────────────────────────────────────────────────

  @dimensions [:accuracy, :completeness, :timeliness, :communication, :efficiency, :innovation]
  @num_dimensions 6
  @default_weights List.duplicate(1.0 / @num_dimensions, @num_dimensions)
  @default_decay 0.95
  @default_min_jobs 5
  @initial_reputation 0.5

  # Anti-gaming thresholds
  @min_variance_threshold 0.001
  @min_completion_seconds 60
  @max_perfect_streak 10

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "A 6-dimensional quality vector"
  @type quality_vector :: [float()]

  @typedoc "Agent reputation history"
  @type agent_history :: %{
          agent_id: String.t(),
          scores: [quality_vector()],
          gaming_flags: [atom()],
          gaming_suspicion: float()
        }

  @typedoc "Internal state"
  @type state :: %{
          histories: %{String.t() => agent_history()},
          weights: [float()],
          decay: float(),
          min_jobs: non_neg_integer()
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the Reputation GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a quality evaluation for an agent after job completion.

  ## Parameters

    * `agent_id` — The agent being evaluated
    * `quality_vector` — A list of exactly 6 floats in [0, 1], corresponding to
      [accuracy, completeness, timeliness, communication, efficiency, innovation]
    * `opts` — Optional metadata:
      - `:completion_seconds` — How long the job took (for rapid-cycling detection)
      - `:client_id` — The client who rated (for self-dealing detection)

  ## Returns

    * `:ok` — Quality recorded and reputation updated
    * `{:error, :invalid_vector}` — Vector does not have exactly 6 elements in [0, 1]
  """
  @spec record_quality(String.t(), quality_vector(), keyword()) :: :ok | {:error, :invalid_vector}
  def record_quality(agent_id, quality_vector, opts \\ []) do
    if valid_quality_vector?(quality_vector) do
      GenServer.cast(__MODULE__, {:record, agent_id, quality_vector, opts})
    else
      {:error, :invalid_vector}
    end
  end

  @doc """
  Computes the current reputation score for an agent.

  Returns the exponentially-weighted inner product of historical quality
  vectors. Returns 0.5 (neutral) for agents with no history.

  ## Returns

    * A float in [0, 1]
  """
  @spec compute_score(String.t()) :: float()
  def compute_score(agent_id) do
    GenServer.call(__MODULE__, {:compute_score, agent_id})
  end

  @doc """
  Computes the trust score for an agent.

  Trust = Reputation x (1 - gaming_suspicion) x min(1, N / N_min)

  ## Returns

    * A float in [0, 1]
  """
  @spec trust_score(String.t()) :: float()
  def trust_score(agent_id) do
    GenServer.call(__MODULE__, {:trust_score, agent_id})
  end

  @doc """
  Returns the full history for an agent, including gaming flags.
  """
  @spec get_history(String.t()) :: {:ok, agent_history()} | {:error, :not_found}
  def get_history(agent_id) do
    GenServer.call(__MODULE__, {:get_history, agent_id})
  end

  @doc """
  Returns the names of the 6 quality dimensions.
  """
  @spec dimensions() :: [atom()]
  def dimensions, do: @dimensions

  @doc """
  Runs anti-gaming detection on an agent and returns any detected anomalies.
  """
  @spec detect_gaming(String.t()) :: [atom()]
  def detect_gaming(agent_id) do
    GenServer.call(__MODULE__, {:detect_gaming, agent_id})
  end

  @doc """
  Updates the weight vector for reputation scoring.

  The weights must sum to 1.0 and have exactly 6 elements.
  """
  @spec set_weights([float()]) :: :ok | {:error, :invalid_weights}
  def set_weights(weights) when length(weights) == @num_dimensions do
    sum = Enum.sum(weights)

    if abs(sum - 1.0) < 0.001 and Enum.all?(weights, &(&1 >= 0)) do
      GenServer.cast(__MODULE__, {:set_weights, weights})
    else
      {:error, :invalid_weights}
    end
  end

  def set_weights(_), do: {:error, :invalid_weights}

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    weights = Keyword.get(opts, :weights, @default_weights)
    decay = Keyword.get(opts, :decay, @default_decay)
    min_jobs = Keyword.get(opts, :min_jobs, @default_min_jobs)

    Logger.info("[Reputation] Initialized with decay=#{decay}, min_jobs=#{min_jobs}")

    {:ok,
     %{
       histories: %{},
       weights: weights,
       decay: decay,
       min_jobs: min_jobs
     }}
  end

  @impl true
  def handle_cast({:record, agent_id, quality_vector, opts}, state) do
    history = Map.get(state.histories, agent_id, new_history(agent_id))

    updated_history = %{
      history
      | scores: history.scores ++ [quality_vector]
    }

    # Run gaming detection on updated history
    gaming_flags = run_gaming_detection(updated_history, opts)

    gaming_suspicion =
      if gaming_flags == [] do
        max(0.0, history.gaming_suspicion - 0.01)
      else
        min(1.0, history.gaming_suspicion + 0.1 * length(gaming_flags))
      end

    final_history = %{
      updated_history
      | gaming_flags: gaming_flags,
        gaming_suspicion: gaming_suspicion
    }

    new_state = %{state | histories: Map.put(state.histories, agent_id, final_history)}

    if gaming_flags != [] do
      Logger.warning(
        "[Reputation] Gaming flags for agent=#{agent_id}: #{inspect(gaming_flags)}"
      )
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:set_weights, weights}, state) do
    {:noreply, %{state | weights: weights}}
  end

  @impl true
  def handle_call({:compute_score, agent_id}, _from, state) do
    history = Map.get(state.histories, agent_id)

    score =
      if history == nil or history.scores == [] do
        @initial_reputation
      else
        exponential_weighted_score(history.scores, state.weights, state.decay)
      end

    {:reply, score, state}
  end

  @impl true
  def handle_call({:trust_score, agent_id}, _from, state) do
    history = Map.get(state.histories, agent_id)

    trust =
      if history == nil do
        0.0
      else
        reputation = exponential_weighted_score(history.scores, state.weights, state.decay)
        gaming_penalty = 1.0 - history.gaming_suspicion
        n = length(history.scores)
        seasoning = min(1.0, n / state.min_jobs)
        reputation * gaming_penalty * seasoning
      end

    {:reply, trust, state}
  end

  @impl true
  def handle_call({:get_history, agent_id}, _from, state) do
    case Map.get(state.histories, agent_id) do
      nil -> {:reply, {:error, :not_found}, state}
      history -> {:reply, {:ok, history}, state}
    end
  end

  @impl true
  def handle_call({:detect_gaming, agent_id}, _from, state) do
    history = Map.get(state.histories, agent_id)

    flags =
      if history == nil do
        []
      else
        run_gaming_detection(history, [])
      end

    {:reply, flags, state}
  end

  # ── Scoring ────────────────────────────────────────────────────────────────

  @spec exponential_weighted_score([quality_vector()], [float()], float()) :: float()
  defp exponential_weighted_score([], _weights, _decay), do: @initial_reputation

  defp exponential_weighted_score(scores, weights, decay) do
    n = length(scores)

    {weighted_sum, weight_total} =
      scores
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {qv, i}, {ws, wt} ->
        decay_factor = :math.pow(decay, n - 1 - i)
        inner_product = inner_product(weights, qv)
        {ws + decay_factor * inner_product, wt + decay_factor}
      end)

    if weight_total == 0.0, do: @initial_reputation, else: weighted_sum / weight_total
  end

  @spec inner_product([float()], [float()]) :: float()
  defp inner_product(weights, values) do
    Enum.zip(weights, values)
    |> Enum.reduce(0.0, fn {w, v}, acc -> acc + w * v end)
  end

  # ── Anti-Gaming Detection ──────────────────────────────────────────────────

  @spec run_gaming_detection(agent_history(), keyword()) :: [atom()]
  defp run_gaming_detection(history, opts) do
    checks = [
      {:score_inflation, &detect_score_inflation/1},
      {:rapid_cycling, &detect_rapid_cycling(&1, opts)},
      {:perfect_streak, &detect_perfect_streak/1}
    ]

    Enum.flat_map(checks, fn {flag, detector} ->
      if detector.(history), do: [flag], else: []
    end)
  end

  @spec detect_score_inflation(agent_history()) :: boolean()
  defp detect_score_inflation(%{scores: scores}) when length(scores) < 3, do: false

  defp detect_score_inflation(%{scores: scores}) do
    # Check if variance across all dimensions is suspiciously low
    flat_scores = List.flatten(scores)
    n = length(flat_scores)

    if n < 2 do
      false
    else
      mean = Enum.sum(flat_scores) / n

      variance =
        flat_scores
        |> Enum.map(fn x -> (x - mean) * (x - mean) end)
        |> Enum.sum()
        |> Kernel./(n - 1)

      variance < @min_variance_threshold
    end
  end

  @spec detect_rapid_cycling(agent_history(), keyword()) :: boolean()
  defp detect_rapid_cycling(%{scores: scores}, opts) when length(scores) < 3, do: false

  defp detect_rapid_cycling(%{scores: scores}, opts) do
    completion_seconds = Keyword.get(opts, :completion_seconds, nil)

    cond do
      completion_seconds != nil and completion_seconds < @min_completion_seconds ->
        # Check if the most recent scores are all high despite fast completion
        recent = Enum.take(scores, -3)
        Enum.all?(recent, fn qv -> Enum.all?(qv, &(&1 > 0.9)) end)

      true ->
        false
    end
  end

  @spec detect_perfect_streak(agent_history()) :: boolean()
  defp detect_perfect_streak(%{scores: scores}) when length(scores) < @max_perfect_streak,
    do: false

  defp detect_perfect_streak(%{scores: scores}) do
    recent = Enum.take(scores, -@max_perfect_streak)
    Enum.all?(recent, fn qv -> Enum.all?(qv, &(&1 >= 0.99)) end)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec new_history(String.t()) :: agent_history()
  defp new_history(agent_id) do
    %{
      agent_id: agent_id,
      scores: [],
      gaming_flags: [],
      gaming_suspicion: 0.0
    }
  end

  @spec valid_quality_vector?(any()) :: boolean()
  defp valid_quality_vector?(qv) when is_list(qv) and length(qv) == @num_dimensions do
    Enum.all?(qv, fn v -> is_number(v) and v >= 0.0 and v <= 1.0 end)
  end

  defp valid_quality_vector?(_), do: false
end
