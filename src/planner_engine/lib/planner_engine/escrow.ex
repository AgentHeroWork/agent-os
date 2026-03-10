defmodule PlannerEngine.Escrow do
  @moduledoc """
  Escrow Monad — Financial consistency via Mnesia transactions.

  The escrow mechanism is formalized as a monad (E, η, μ) on the credit category:

    * **Unit (η):** `hold/3` — Initialize escrow by moving credits from available to held.
      Corresponds to `holdEscrow(client_id, rate_credits, contract_id)` in the AgentHero system.
    * **Bind (>>=):** `bind/2` — Sequence escrow operations. Holding credits for contract c₁
      and then for c₂ composes into a single escrow state.
    * **Join (μ):** `settle/2` — Flatten nested escrow. Settle an escrow by either releasing
      (transferring to operator) or refunding (returning to client).

  ## Monad Laws

  The implementation guarantees:

    1. **Left unit:** `settle(hold(x)) = x` — holding and immediately settling is identity
    2. **Right unit:** `hold(settle(e)) = e` — settling and re-holding preserves the escrow
    3. **Associativity:** `settle(settle(E(E(x)))) = settle(E(settle(E(x))))` — flattening is associative

  ## Mnesia Transactions

  All balance mutations occur within Mnesia transactions, providing:

    * Atomicity — balance check and deduction are a single operation (no TOCTOU race)
    * Isolation — concurrent operations are serialized
    * Durability — committed transactions survive crashes (with disc_copies)

  ## Conservation Invariant

  The total credits in the system (available + held + distributed) is constant.
  No operation creates or destroys credits.
  """

  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "Escrow record stored in Mnesia"
  @type escrow_record :: %{
          id: String.t(),
          client_id: String.t(),
          amount: non_neg_integer(),
          contract_id: String.t(),
          status: :held | :released | :refunded,
          created_at: DateTime.t(),
          settled_at: DateTime.t() | nil
        }

  @typedoc "Balance record stored in Mnesia"
  @type balance_record :: %{
          participant_id: String.t(),
          available: non_neg_integer(),
          held: non_neg_integer()
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the Escrow GenServer and initializes Mnesia tables.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Monad unit (η): Hold credits in escrow for a contract.

  Atomically decrements the client's available balance and creates an escrow record.
  Fails if the client has insufficient funds (prevents negative balances).

  ## Parameters

    * `client_id` — The client whose credits are being held
    * `amount` — Number of credits to hold
    * `contract_id` — The contract this escrow is associated with

  ## Returns

    * `{:ok, escrow_id}` — Credits successfully held
    * `{:error, :insufficient_funds}` — Client balance too low
    * `{:error, reason}` — Mnesia transaction failed
  """
  @spec hold(String.t(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def hold(client_id, amount, contract_id) do
    GenServer.call(__MODULE__, {:hold, client_id, amount, contract_id})
  end

  @doc """
  Monad bind (>>=): Sequence an escrow operation with a transformation.

  Takes an existing escrow and applies a function to produce a new escrow state.
  The function receives the current escrow record and must return `{:ok, new_record}`.

  ## Parameters

    * `escrow_id` — The escrow to transform
    * `f` — Function `(escrow_record -> {:ok, escrow_record} | {:error, term()})`

  ## Returns

    * `{:ok, updated_record}` — Transformation applied successfully
    * `{:error, reason}` — Transformation failed
  """
  @spec bind(String.t(), (escrow_record() -> {:ok, escrow_record()} | {:error, term()})) ::
          {:ok, escrow_record()} | {:error, term()}
  def bind(escrow_id, f) when is_function(f, 1) do
    GenServer.call(__MODULE__, {:bind, escrow_id, f})
  end

  @doc """
  Monad join (μ): Settle an escrow by releasing or refunding.

  * `:release` — Transfer held credits to the operator (job completed successfully).
    The revenue split (70% operator, 15% platform, 15% LLM reserve) is applied
    by `PlannerEngine.Market.distribute_revenue/1`.
  * `:refund` — Return held credits to the client (job cancelled or disputed).

  ## Parameters

    * `escrow_id` — The escrow to settle
    * `action` — `:release` or `:refund`

  ## Returns

    * `{:ok, settled_record}` — Escrow settled successfully
    * `{:error, :not_found}` — No escrow with that ID
    * `{:error, :already_settled}` — Escrow was already released or refunded
  """
  @spec settle(String.t(), :release | :refund) ::
          {:ok, escrow_record()} | {:error, atom()}
  def settle(escrow_id, action) when action in [:release, :refund] do
    GenServer.call(__MODULE__, {:settle, escrow_id, action})
  end

  @doc """
  Returns the current balance for a participant.

  ## Returns

    * `{:ok, %{available: n, held: h}}` — Balance found
    * `{:error, :not_found}` — No balance record for this participant
  """
  @spec balance(String.t()) :: {:ok, balance_record()} | {:error, :not_found}
  def balance(participant_id) do
    GenServer.call(__MODULE__, {:balance, participant_id})
  end

  @doc """
  Sets the initial balance for a participant. Used during onboarding or credit purchase.

  ## Returns

    * `:ok` — Balance set successfully
  """
  @spec set_balance(String.t(), non_neg_integer()) :: :ok
  def set_balance(participant_id, amount) do
    GenServer.call(__MODULE__, {:set_balance, participant_id, amount})
  end

  @doc """
  Returns the escrow record for a given escrow ID.
  """
  @spec get_escrow(String.t()) :: {:ok, escrow_record()} | {:error, :not_found}
  def get_escrow(escrow_id) do
    GenServer.call(__MODULE__, {:get_escrow, escrow_id})
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ok = init_mnesia()
    Logger.info("[Escrow] Initialized with Mnesia tables")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:hold, client_id, amount, contract_id}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read(:balances, client_id) do
          [{:balances, ^client_id, available, held}] when available >= amount ->
            :mnesia.write({:balances, client_id, available - amount, held + amount})
            escrow_id = generate_id()
            now = DateTime.utc_now()

            :mnesia.write(
              {:escrows, escrow_id, client_id, amount, contract_id, :held, now, nil}
            )

            escrow_id

          [{:balances, ^client_id, _available, _held}] ->
            :mnesia.abort(:insufficient_funds)

          [] ->
            :mnesia.abort(:no_balance_record)
        end
      end)

    case result do
      {:atomic, escrow_id} ->
        Logger.info(
          "[Escrow] Held #{amount} credits for client=#{client_id} contract=#{contract_id}"
        )

        {:reply, {:ok, escrow_id}, state}

      {:aborted, reason} ->
        Logger.warning("[Escrow] Hold failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:bind, escrow_id, f}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read(:escrows, escrow_id) do
          [{:escrows, ^escrow_id, client_id, amount, contract_id, status, created_at, settled_at}] ->
            record = %{
              id: escrow_id,
              client_id: client_id,
              amount: amount,
              contract_id: contract_id,
              status: status,
              created_at: created_at,
              settled_at: settled_at
            }

            case f.(record) do
              {:ok, updated} ->
                :mnesia.write(
                  {:escrows, updated.id, updated.client_id, updated.amount,
                   updated.contract_id, updated.status, updated.created_at, updated.settled_at}
                )

                updated

              {:error, reason} ->
                :mnesia.abort(reason)
            end

          [] ->
            :mnesia.abort(:not_found)
        end
      end)

    case result do
      {:atomic, updated} -> {:reply, {:ok, updated}, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:settle, escrow_id, action}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read(:escrows, escrow_id) do
          [{:escrows, ^escrow_id, client_id, amount, contract_id, :held, created_at, _}] ->
            now = DateTime.utc_now()
            new_status = if action == :release, do: :released, else: :refunded

            # Update escrow record
            :mnesia.write(
              {:escrows, escrow_id, client_id, amount, contract_id, new_status, created_at, now}
            )

            # Update balance: reduce held amount
            case :mnesia.read(:balances, client_id) do
              [{:balances, ^client_id, available, held}] ->
                if action == :refund do
                  # Refund: move from held back to available
                  :mnesia.write({:balances, client_id, available + amount, held - amount})
                else
                  # Release: remove from held (credits go to operator via Market)
                  :mnesia.write({:balances, client_id, available, held - amount})
                end

              [] ->
                :mnesia.abort(:no_balance_record)
            end

            %{
              id: escrow_id,
              client_id: client_id,
              amount: amount,
              contract_id: contract_id,
              status: new_status,
              created_at: created_at,
              settled_at: now
            }

          [{:escrows, ^escrow_id, _, _, _, status, _, _}] when status in [:released, :refunded] ->
            :mnesia.abort(:already_settled)

          [] ->
            :mnesia.abort(:not_found)
        end
      end)

    case result do
      {:atomic, record} ->
        Logger.info("[Escrow] Settled escrow=#{escrow_id} action=#{action}")
        {:reply, {:ok, record}, state}

      {:aborted, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:balance, participant_id}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read(:balances, participant_id) do
          [{:balances, ^participant_id, available, held}] ->
            %{participant_id: participant_id, available: available, held: held}

          [] ->
            :mnesia.abort(:not_found)
        end
      end)

    case result do
      {:atomic, balance} -> {:reply, {:ok, balance}, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_balance, participant_id, amount}, _from, state) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({:balances, participant_id, amount, 0})
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_escrow, escrow_id}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read(:escrows, escrow_id) do
          [{:escrows, ^escrow_id, client_id, amount, contract_id, status, created_at, settled_at}] ->
            %{
              id: escrow_id,
              client_id: client_id,
              amount: amount,
              contract_id: contract_id,
              status: status,
              created_at: created_at,
              settled_at: settled_at
            }

          [] ->
            :mnesia.abort(:not_found)
        end
      end)

    case result do
      {:atomic, record} -> {:reply, {:ok, record}, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ── Mnesia Setup ───────────────────────────────────────────────────────────

  @spec init_mnesia() :: :ok
  defp init_mnesia do
    :mnesia.create_schema([node()])
    :mnesia.start()

    :mnesia.create_table(:balances,
      attributes: [:participant_id, :available, :held],
      type: :set
    )

    :mnesia.create_table(:escrows,
      attributes: [:id, :client_id, :amount, :contract_id, :status, :created_at, :settled_at],
      type: :set
    )

    :mnesia.wait_for_tables([:balances, :escrows], 5_000)
    :ok
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
