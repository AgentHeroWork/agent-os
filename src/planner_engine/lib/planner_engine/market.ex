defmodule PlannerEngine.Market do
  @moduledoc """
  Market Clearing and Revenue Distribution.

  Implements market clearing as a colimit in the transaction category and revenue
  distribution as a natural transformation between credit functors.

  ## Market Clearing (Colimit)

  When a client accepts a proposal for a task, the market clears:

    1. The accepted proposal becomes a contract
    2. All other proposals are auto-rejected (universal property of the colimit)
    3. Credits are held in escrow via `PlannerEngine.Escrow.hold/3`
    4. The job transitions from `open` → `in_progress`

  ## Revenue Split

  Upon contract completion, escrowed credits are distributed:

    * **70%** → Operator (the agent who performed the work)
    * **15%** → Platform (marketplace fee)
    * **15%** → LLM Reserve (covers inference costs)

  ## Pricing Models

  Three pricing models determine the total billable amount:

    * `:per_task` — Fixed price for the entire task
    * `:hourly` — Rate per hour × ceiling of hours worked
    * `:per_token` — Rate per token × tokens consumed

  In all cases, the total is capped at the budget ceiling to prevent overspend.

  ## Atomic Operations

  All financial operations use `PlannerEngine.Escrow` which provides Mnesia
  transaction guarantees, preventing race conditions and negative balances.
  """

  use GenServer

  require Logger

  # ── Constants ──────────────────────────────────────────────────────────────

  @operator_share 0.70
  @platform_share 0.15
  @llm_reserve_share 0.15
  # Suppress unused warning — reserved for future LLM cost accounting
  _ = @llm_reserve_share

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Contract status in the job lifecycle"
  @type contract_status :: :active | :completed | :cancelled | :disputed | :review

  @typedoc "Pricing model for a contract"
  @type pricing_model :: :per_task | :hourly | :per_token

  @typedoc "A contract between a client and an operator"
  @type contract :: %{
          id: String.t(),
          client_id: String.t(),
          operator_id: String.t(),
          task_id: String.t(),
          escrow_id: String.t() | nil,
          status: contract_status(),
          pricing_model: pricing_model(),
          rate_credits: non_neg_integer(),
          budget_ceiling: non_neg_integer(),
          hours_worked: float(),
          tokens_consumed: non_neg_integer(),
          created_at: DateTime.t(),
          completed_at: DateTime.t() | nil
        }

  @typedoc "Revenue distribution breakdown"
  @type revenue_split :: %{
          total: non_neg_integer(),
          operator: non_neg_integer(),
          platform: non_neg_integer(),
          llm_reserve: non_neg_integer()
        }

  @typedoc "Internal state"
  @type state :: %{
          contracts: %{String.t() => contract()},
          revenue_log: [%{contract_id: String.t(), split: revenue_split(), timestamp: DateTime.t()}]
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the Market GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Clears the market for a task by accepting the best proposal.

  This implements the colimit construction:

    1. Fetches the best proposal from the OrderBook
    2. Accepts it (auto-rejecting all others)
    3. Holds credits in escrow
    4. Creates a contract

  ## Parameters

    * `task_id` — The task to clear

  ## Returns

    * `{:ok, contract}` — Market cleared, contract created
    * `{:error, :no_proposals}` — No proposals available for this task
    * `{:error, :no_demand}` — No demand posted for this task
    * `{:error, :escrow_failed}` — Escrow hold failed (insufficient funds)
  """
  @spec clear_market(String.t()) :: {:ok, contract()} | {:error, atom()}
  def clear_market(task_id) do
    GenServer.call(__MODULE__, {:clear_market, task_id})
  end

  @doc """
  Creates a contract directly from a matched proposal and demand.

  Used when the OrderBook has already performed matching. Handles escrow creation.

  ## Parameters

    * `match_result` — A match result from `PlannerEngine.OrderBook`
    * `pricing_model` — One of `:per_task`, `:hourly`, `:per_token`

  ## Returns

    * `{:ok, contract}` — Contract created with escrow
    * `{:error, reason}` — Failed to create contract
  """
  @spec create_contract(map(), pricing_model()) :: {:ok, contract()} | {:error, atom()}
  def create_contract(match_result, pricing_model \\ :per_task) do
    GenServer.call(__MODULE__, {:create_contract, match_result, pricing_model})
  end

  @doc """
  Transitions a contract to review status.

  Called when the operator submits deliverables for client review.
  """
  @spec submit_for_review(String.t()) :: {:ok, contract()} | {:error, atom()}
  def submit_for_review(contract_id) do
    GenServer.call(__MODULE__, {:transition, contract_id, :review})
  end

  @doc """
  Completes a contract, distributing revenue.

  Settles the escrow and distributes credits according to the revenue split:
  70% operator, 15% platform, 15% LLM reserve.

  Also triggers reputation update via `PlannerEngine.Reputation.record_quality/3`.

  ## Parameters

    * `contract_id` — The contract to complete
    * `quality_vector` — 6-dimensional quality assessment [0, 1]^6

  ## Returns

    * `{:ok, %{contract: contract, split: revenue_split}}` — Completed and distributed
    * `{:error, reason}` — Failed to complete
  """
  @spec complete_contract(String.t(), [float()]) :: {:ok, map()} | {:error, atom()}
  def complete_contract(contract_id, quality_vector \\ [0.8, 0.8, 0.8, 0.8, 0.8, 0.8]) do
    GenServer.call(__MODULE__, {:complete, contract_id, quality_vector})
  end

  @doc """
  Cancels a contract, refunding escrowed credits to the client.
  """
  @spec cancel_contract(String.t()) :: {:ok, contract()} | {:error, atom()}
  def cancel_contract(contract_id) do
    GenServer.call(__MODULE__, {:cancel, contract_id})
  end

  @doc """
  Disputes a contract. Escrow remains held until resolution.
  """
  @spec dispute_contract(String.t()) :: {:ok, contract()} | {:error, atom()}
  def dispute_contract(contract_id) do
    GenServer.call(__MODULE__, {:transition, contract_id, :disputed})
  end

  @doc """
  Returns a contract by ID.
  """
  @spec get_contract(String.t()) :: {:ok, contract()} | {:error, :not_found}
  def get_contract(contract_id) do
    GenServer.call(__MODULE__, {:get_contract, contract_id})
  end

  @doc """
  Returns all contracts for a given participant (client or operator).
  """
  @spec contracts_for(String.t()) :: [contract()]
  def contracts_for(participant_id) do
    GenServer.call(__MODULE__, {:contracts_for, participant_id})
  end

  @doc """
  Computes the revenue split for a given total amount.

  ## Returns

    * `%{total: n, operator: n1, platform: n2, llm_reserve: n3}`
  """
  @spec compute_split(non_neg_integer()) :: revenue_split()
  def compute_split(total) do
    operator = round(total * @operator_share)
    platform = round(total * @platform_share)
    llm_reserve = total - operator - platform

    %{
      total: total,
      operator: operator,
      platform: platform,
      llm_reserve: llm_reserve
    }
  end

  @doc """
  Computes the billable total for a contract based on its pricing model.

  Caps at budget_ceiling to prevent overspend.
  """
  @spec compute_total(contract()) :: non_neg_integer()
  def compute_total(contract) do
    raw =
      case contract.pricing_model do
        :per_task ->
          contract.rate_credits

        :hourly ->
          contract.rate_credits * ceil(contract.hours_worked)

        :per_token ->
          Map.get(contract, :rate_per_token, contract.rate_credits) * contract.tokens_consumed
      end

    min(raw, contract.budget_ceiling)
  end

  @doc """
  Returns the cumulative revenue log.
  """
  @spec revenue_log() :: [map()]
  def revenue_log do
    GenServer.call(__MODULE__, :revenue_log)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("[Market] Initialized")
    {:ok, %{contracts: %{}, revenue_log: []}}
  end

  @impl true
  def handle_call({:clear_market, task_id}, _from, state) do
    with {:ok, best_proposal} <- PlannerEngine.OrderBook.best_proposal(task_id),
         demands when demands != [] <- PlannerEngine.OrderBook.demands_for_task(task_id),
         demand <- hd(demands),
         {:ok, _match} <- PlannerEngine.OrderBook.accept_proposal(best_proposal.id) do
      # Create contract with escrow
      case create_contract_internal(state, demand, best_proposal, :per_task) do
        {:ok, contract, new_state} ->
          Logger.info("[Market] Cleared market for task=#{task_id} contract=#{contract.id}")
          {:reply, {:ok, contract}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, :no_proposals} -> {:reply, {:error, :no_proposals}, state}
      [] -> {:reply, {:error, :no_demand}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:create_contract, match_result, pricing_model}, _from, state) do
    demand = match_result.demand
    proposal = match_result.proposal

    case create_contract_internal(state, demand, proposal, pricing_model) do
      {:ok, contract, new_state} ->
        {:reply, {:ok, contract}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:transition, contract_id, new_status}, _from, state) do
    case Map.get(state.contracts, contract_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      contract ->
        if valid_transition?(contract.status, new_status) do
          updated = %{contract | status: new_status}
          new_state = %{state | contracts: Map.put(state.contracts, contract_id, updated)}
          {:reply, {:ok, updated}, new_state}
        else
          {:reply, {:error, :invalid_transition}, state}
        end
    end
  end

  @impl true
  def handle_call({:complete, contract_id, quality_vector}, _from, state) do
    case Map.get(state.contracts, contract_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} = contract when status in [:active, :review] ->
        # Settle escrow (release to operator)
        escrow_result =
          if contract.escrow_id do
            PlannerEngine.Escrow.settle(contract.escrow_id, :release)
          else
            {:ok, nil}
          end

        case escrow_result do
          {:ok, _} ->
            # Compute revenue split
            total = compute_total(contract)
            split = compute_split(total)
            now = DateTime.utc_now()

            completed_contract = %{contract | status: :completed, completed_at: now}

            revenue_entry = %{
              contract_id: contract_id,
              split: split,
              timestamp: now
            }

            new_state = %{
              state
              | contracts: Map.put(state.contracts, contract_id, completed_contract),
                revenue_log: [revenue_entry | state.revenue_log]
            }

            # Record quality for reputation
            PlannerEngine.Reputation.record_quality(contract.operator_id, quality_vector)

            Logger.info(
              "[Market] Completed contract=#{contract_id} " <>
                "operator_payout=#{split.operator} platform_fee=#{split.platform}"
            )

            {:reply, {:ok, %{contract: completed_contract, split: split}}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      %{status: status} ->
        {:reply, {:error, {:invalid_status, status}}, state}
    end
  end

  @impl true
  def handle_call({:cancel, contract_id}, _from, state) do
    case Map.get(state.contracts, contract_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} = contract when status in [:active, :review, :disputed] ->
        # Refund escrow
        if contract.escrow_id do
          PlannerEngine.Escrow.settle(contract.escrow_id, :refund)
        end

        cancelled = %{contract | status: :cancelled}
        new_state = %{state | contracts: Map.put(state.contracts, contract_id, cancelled)}

        Logger.info("[Market] Cancelled contract=#{contract_id}")
        {:reply, {:ok, cancelled}, new_state}

      %{status: status} ->
        {:reply, {:error, {:invalid_status, status}}, state}
    end
  end

  @impl true
  def handle_call({:get_contract, contract_id}, _from, state) do
    case Map.get(state.contracts, contract_id) do
      nil -> {:reply, {:error, :not_found}, state}
      contract -> {:reply, {:ok, contract}, state}
    end
  end

  @impl true
  def handle_call({:contracts_for, participant_id}, _from, state) do
    contracts =
      state.contracts
      |> Map.values()
      |> Enum.filter(fn c ->
        c.client_id == participant_id or c.operator_id == participant_id
      end)

    {:reply, contracts, state}
  end

  @impl true
  def handle_call(:revenue_log, _from, state) do
    {:reply, state.revenue_log, state}
  end

  # ── Private Functions ──────────────────────────────────────────────────────

  @spec create_contract_internal(state(), map(), map(), pricing_model()) ::
          {:ok, contract(), state()} | {:error, atom()}
  defp create_contract_internal(state, demand, proposal, pricing_model) do
    contract_id = generate_id()

    # Hold escrow
    escrow_result =
      PlannerEngine.Escrow.hold(
        demand.client_id,
        proposal.estimated_credits,
        contract_id
      )

    case escrow_result do
      {:ok, escrow_id} ->
        contract = %{
          id: contract_id,
          client_id: demand.client_id,
          operator_id: proposal.agent_id,
          task_id: demand.task_id,
          escrow_id: escrow_id,
          status: :active,
          pricing_model: pricing_model,
          rate_credits: proposal.estimated_credits,
          budget_ceiling: demand.budget_ceiling,
          hours_worked: 0.0,
          tokens_consumed: 0,
          created_at: DateTime.utc_now(),
          completed_at: nil
        }

        new_state = %{state | contracts: Map.put(state.contracts, contract_id, contract)}
        {:ok, contract, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec valid_transition?(contract_status(), contract_status()) :: boolean()
  defp valid_transition?(:active, :review), do: true
  defp valid_transition?(:active, :cancelled), do: true
  defp valid_transition?(:active, :disputed), do: true
  defp valid_transition?(:review, :completed), do: true
  defp valid_transition?(:review, :disputed), do: true
  defp valid_transition?(:review, :cancelled), do: true
  defp valid_transition?(:disputed, :completed), do: true
  defp valid_transition?(:disputed, :cancelled), do: true
  defp valid_transition?(_, _), do: false

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
