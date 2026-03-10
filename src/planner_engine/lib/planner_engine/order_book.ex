defmodule PlannerEngine.OrderBook do
  @moduledoc """
  Order Book — Profunctor-based matching engine.

  Models the order book as a profunctor P: Agents^op × Tasks → Set, where
  P(α, τ) is the set of proposals from agent α for task τ. The matching
  engine implements price-time priority ordering and produces matches when
  a proposal satisfies a demand's constraints.

  ## Matching Algorithm

  Proposals (sell orders) and demands (buy orders) are indexed by task_id.
  When a new proposal or demand arrives, the engine checks for a match:

    1. Proposals are sorted by (estimated_credits ASC, timestamp ASC) — price-time priority
    2. A match occurs when the best proposal's credits ≤ demand's budget_ceiling
    3. Upon match, a contract is created, all other proposals are auto-rejected (colimit property)

  ## Profunctor Action

    * **Contravariant in Agents:** If agent α' ≤ α (capability subsumption),
      proposals from α' lift to proposals from α.
    * **Covariant in Tasks:** If τ → τ' (dependency), completing τ enables proposals for τ'.
  """

  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "A proposal (sell order) from an agent for a task"
  @type proposal :: %{
          id: String.t(),
          agent_id: String.t(),
          task_id: String.t(),
          execution_plan: String.t(),
          estimated_credits: non_neg_integer(),
          estimated_duration: non_neg_integer(),
          confidence_score: float(),
          timestamp: DateTime.t(),
          status: :pending | :accepted | :rejected
        }

  @typedoc "A demand (buy order) from a client for a task"
  @type demand :: %{
          id: String.t(),
          client_id: String.t(),
          task_id: String.t(),
          required_capabilities: [atom()],
          budget_ceiling: non_neg_integer(),
          deadline: DateTime.t(),
          timestamp: DateTime.t(),
          status: :open | :matched | :cancelled
        }

  @typedoc "A match between a demand and a proposal"
  @type match_result :: %{
          demand: demand(),
          proposal: proposal(),
          matched_at: DateTime.t()
        }

  @typedoc "Internal state of the order book"
  @type state :: %{
          proposals: %{String.t() => [proposal()]},
          demands: %{String.t() => [demand()]},
          matches: [match_result()]
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the OrderBook GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submits a proposal (sell order) from an agent for a task.

  The proposal is inserted into the order book in price-time priority order.
  If a matching demand exists, a match is triggered immediately.

  ## Parameters

    * `proposal` — Map with keys: `:agent_id`, `:task_id`, `:execution_plan`,
      `:estimated_credits`, `:estimated_duration`, `:confidence_score`

  ## Returns

    * `:ok` — Proposal accepted into the order book
    * `{:matched, match_result}` — Proposal immediately matched with a demand
  """
  @spec submit_proposal(map()) :: :ok | {:matched, match_result()}
  def submit_proposal(proposal) do
    GenServer.call(__MODULE__, {:submit_proposal, proposal})
  end

  @doc """
  Posts a demand (buy order) from a client for a task.

  ## Parameters

    * `demand` — Map with keys: `:client_id`, `:task_id`, `:required_capabilities`,
      `:budget_ceiling`, `:deadline`

  ## Returns

    * `:ok` — Demand posted to the order book
    * `{:matched, match_result}` — Demand immediately matched with a proposal
  """
  @spec post_demand(map()) :: :ok | {:matched, match_result()}
  def post_demand(demand) do
    GenServer.call(__MODULE__, {:post_demand, demand})
  end

  @doc """
  Returns all pending proposals for a given task.
  """
  @spec proposals_for_task(String.t()) :: [proposal()]
  def proposals_for_task(task_id) do
    GenServer.call(__MODULE__, {:proposals_for_task, task_id})
  end

  @doc """
  Returns all pending demands for a given task.
  """
  @spec demands_for_task(String.t()) :: [demand()]
  def demands_for_task(task_id) do
    GenServer.call(__MODULE__, {:demands_for_task, task_id})
  end

  @doc """
  Returns the best (lowest cost-adjusted) proposal for a task.

  The cost functional is:

      cost(α, τ) = estimated_credits / (1 + confidence_score × reputation)

  where reputation defaults to 0.5 if not provided.
  """
  @spec best_proposal(String.t()) :: {:ok, proposal()} | {:error, :no_proposals}
  def best_proposal(task_id) do
    GenServer.call(__MODULE__, {:best_proposal, task_id})
  end

  @doc """
  Accepts a specific proposal, auto-rejecting all others for the same task.

  This implements the colimit universal property: accepting one proposal
  necessarily rejects all alternatives.

  ## Returns

    * `{:ok, match_result}` — Proposal accepted and match recorded
    * `{:error, :not_found}` — Proposal not found
  """
  @spec accept_proposal(String.t()) :: {:ok, match_result()} | {:error, :not_found}
  def accept_proposal(proposal_id) do
    GenServer.call(__MODULE__, {:accept_proposal, proposal_id})
  end

  @doc """
  Returns all completed matches.
  """
  @spec all_matches() :: [match_result()]
  def all_matches do
    GenServer.call(__MODULE__, :all_matches)
  end

  @doc """
  Returns the current order book depth for a task: {num_proposals, num_demands}.
  """
  @spec depth(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def depth(task_id) do
    GenServer.call(__MODULE__, {:depth, task_id})
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("[OrderBook] Initialized")
    {:ok, %{proposals: %{}, demands: %{}, matches: []}}
  end

  @impl true
  def handle_call({:submit_proposal, raw_proposal}, _from, state) do
    proposal = normalize_proposal(raw_proposal)
    task_id = proposal.task_id

    proposals =
      Map.update(state.proposals, task_id, [proposal], fn existing ->
        insert_by_priority(existing, proposal)
      end)

    new_state = %{state | proposals: proposals}

    case try_match(new_state, task_id) do
      {:matched, match_result, matched_state} ->
        Logger.info("[OrderBook] Immediate match for task #{task_id}")
        {:reply, {:matched, match_result}, matched_state}

      :no_match ->
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:post_demand, raw_demand}, _from, state) do
    demand = normalize_demand(raw_demand)
    task_id = demand.task_id

    demands =
      Map.update(state.demands, task_id, [demand], fn existing ->
        [demand | existing]
      end)

    new_state = %{state | demands: demands}

    case try_match(new_state, task_id) do
      {:matched, match_result, matched_state} ->
        Logger.info("[OrderBook] Immediate match for task #{task_id}")
        {:reply, {:matched, match_result}, matched_state}

      :no_match ->
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:proposals_for_task, task_id}, _from, state) do
    proposals =
      state.proposals
      |> Map.get(task_id, [])
      |> Enum.filter(&(&1.status == :pending))

    {:reply, proposals, state}
  end

  @impl true
  def handle_call({:demands_for_task, task_id}, _from, state) do
    demands =
      state.demands
      |> Map.get(task_id, [])
      |> Enum.filter(&(&1.status == :open))

    {:reply, demands, state}
  end

  @impl true
  def handle_call({:best_proposal, task_id}, _from, state) do
    case get_pending_proposals(state, task_id) do
      [] ->
        {:reply, {:error, :no_proposals}, state}

      proposals ->
        best = Enum.min_by(proposals, &cost_functional/1)
        {:reply, {:ok, best}, state}
    end
  end

  @impl true
  def handle_call({:accept_proposal, proposal_id}, _from, state) do
    case find_proposal(state, proposal_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {task_id, proposal} ->
        {match_result, new_state} = execute_accept(state, task_id, proposal)
        {:reply, {:ok, match_result}, new_state}
    end
  end

  @impl true
  def handle_call(:all_matches, _from, state) do
    {:reply, state.matches, state}
  end

  @impl true
  def handle_call({:depth, task_id}, _from, state) do
    num_proposals = state.proposals |> Map.get(task_id, []) |> Enum.count(&(&1.status == :pending))
    num_demands = state.demands |> Map.get(task_id, []) |> Enum.count(&(&1.status == :open))
    {:reply, {num_proposals, num_demands}, state}
  end

  # ── Private Functions ──────────────────────────────────────────────────────

  @spec normalize_proposal(map()) :: proposal()
  defp normalize_proposal(raw) do
    %{
      id: Map.get(raw, :id, generate_id()),
      agent_id: raw.agent_id,
      task_id: raw.task_id,
      execution_plan: raw.execution_plan,
      estimated_credits: raw.estimated_credits,
      estimated_duration: raw.estimated_duration,
      confidence_score: raw.confidence_score,
      timestamp: Map.get(raw, :timestamp, DateTime.utc_now()),
      status: :pending
    }
  end

  @spec normalize_demand(map()) :: demand()
  defp normalize_demand(raw) do
    %{
      id: Map.get(raw, :id, generate_id()),
      client_id: raw.client_id,
      task_id: raw.task_id,
      required_capabilities: Map.get(raw, :required_capabilities, []),
      budget_ceiling: raw.budget_ceiling,
      deadline: Map.get(raw, :deadline, DateTime.utc_now()),
      timestamp: Map.get(raw, :timestamp, DateTime.utc_now()),
      status: :open
    }
  end

  @spec insert_by_priority([proposal()], proposal()) :: [proposal()]
  defp insert_by_priority(existing, new_proposal) do
    [new_proposal | existing]
    |> Enum.sort_by(fn p -> {p.estimated_credits, DateTime.to_unix(p.timestamp)} end)
  end

  @spec try_match(state(), String.t()) :: {:matched, match_result(), state()} | :no_match
  defp try_match(state, task_id) do
    pending_demands = get_open_demands(state, task_id)
    pending_proposals = get_pending_proposals(state, task_id)

    with [demand | _] <- pending_demands,
         [best_proposal | _] <- pending_proposals,
         true <- best_proposal.estimated_credits <= demand.budget_ceiling do
      {match_result, new_state} = execute_accept(state, task_id, best_proposal)
      {:matched, match_result, new_state}
    else
      _ -> :no_match
    end
  end

  @spec execute_accept(state(), String.t(), proposal()) :: {match_result(), state()}
  defp execute_accept(state, task_id, accepted_proposal) do
    [demand | remaining_demands] = get_open_demands(state, task_id)
    now = DateTime.utc_now()

    match_result = %{
      demand: %{demand | status: :matched},
      proposal: %{accepted_proposal | status: :accepted},
      matched_at: now
    }

    # Auto-reject all other proposals (colimit universal property)
    updated_proposals =
      state.proposals
      |> Map.get(task_id, [])
      |> Enum.map(fn p ->
        if p.id == accepted_proposal.id do
          %{p | status: :accepted}
        else
          %{p | status: :rejected}
        end
      end)

    # Update demand status
    updated_demands =
      [%{demand | status: :matched} | remaining_demands]

    new_state = %{
      state
      | proposals: Map.put(state.proposals, task_id, updated_proposals),
        demands: Map.put(state.demands, task_id, updated_demands),
        matches: [match_result | state.matches]
    }

    Logger.info(
      "[OrderBook] Match: agent=#{accepted_proposal.agent_id} task=#{task_id} " <>
        "credits=#{accepted_proposal.estimated_credits}"
    )

    {match_result, new_state}
  end

  @spec get_pending_proposals(state(), String.t()) :: [proposal()]
  defp get_pending_proposals(state, task_id) do
    state.proposals
    |> Map.get(task_id, [])
    |> Enum.filter(&(&1.status == :pending))
  end

  @spec get_open_demands(state(), String.t()) :: [demand()]
  defp get_open_demands(state, task_id) do
    state.demands
    |> Map.get(task_id, [])
    |> Enum.filter(&(&1.status == :open))
  end

  @spec find_proposal(state(), String.t()) :: {String.t(), proposal()} | nil
  defp find_proposal(state, proposal_id) do
    Enum.find_value(state.proposals, fn {task_id, proposals} ->
      case Enum.find(proposals, &(&1.id == proposal_id && &1.status == :pending)) do
        nil -> nil
        proposal -> {task_id, proposal}
      end
    end)
  end

  @spec cost_functional(proposal()) :: float()
  defp cost_functional(proposal) do
    reputation = Map.get(proposal, :reputation, 0.5)
    proposal.estimated_credits / (1.0 + proposal.confidence_score * reputation)
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
