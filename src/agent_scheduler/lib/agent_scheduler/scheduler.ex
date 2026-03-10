defmodule AgentScheduler.Scheduler do
  @moduledoc """
  Priority-based, credit-weighted agent scheduler.

  Implements Algorithm 1 from the paper: credit-weighted agent scheduling using
  agent virtual runtime (avruntime). The design directly generalizes the Linux
  Completely Fair Scheduler (CFS):

  - Each client accumulates virtual runtime proportional to credits consumed,
    weighted inversely by their credit balance and priority level.
  - The scheduler always dispatches the client-agent pair with the smallest avruntime.
  - Contracted clients preempt marketplace clients (two-tier scheduling).

  ## Virtual Runtime Formula

      avruntime(c) += κ_A × cr_0 / (cr_c × w(p_c))

  Where:
    - `κ_A` = agent cost per invocation
    - `cr_0` = reference credit amount (1000)
    - `cr_c` = client's remaining credits
    - `w(p_c)` = priority weight

  ## Implementation

  Uses Erlang's `:gb_trees` (general balanced trees) for O(log n) enqueue/dequeue,
  matching the complexity of Linux CFS's red-black tree implementation.
  """

  use GenServer
  require Logger

  # -- Types --

  @type client_id :: String.t()
  @type agent_id :: String.t()
  @type priority :: :contracted | :marketplace
  @type queue_entry :: {float(), client_id(), agent_id()}

  @type t :: %__MODULE__{
          queue: :gb_trees.tree(),
          vruntimes: %{client_id() => float()},
          client_credits: %{client_id() => non_neg_integer()},
          client_priorities: %{client_id() => priority()},
          reference_credits: pos_integer(),
          dispatched_count: non_neg_integer(),
          sequence: non_neg_integer()
        }

  defstruct [
    :queue,
    vruntimes: %{},
    client_credits: %{},
    client_priorities: %{},
    reference_credits: 1000,
    dispatched_count: 0,
    sequence: 0
  ]

  # Priority weights: contracted work gets 4x the scheduling weight
  @priority_weights %{
    contracted: 4.0,
    marketplace: 1.0
  }

  # -- Client API --

  @doc """
  Starts the scheduler GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a job for scheduling.

  The job is placed in the priority queue keyed by the client's current avruntime.
  Lower avruntime = higher scheduling priority (client has used fewer resources
  relative to their credits).

  ## Parameters

    - `client_id` — The client submitting the job
    - `job` — Job specification map with `:id`, `:task`, `:input`, etc.
    - `opts` — Options including `:agent_id` for specific agent assignment
  """
  @spec enqueue(client_id(), map(), keyword()) :: :ok | {:error, term()}
  def enqueue(client_id, job, opts \\ []) do
    GenServer.call(__MODULE__, {:enqueue, client_id, job, opts})
  end

  @doc """
  Dequeues and dispatches the next job.

  Returns the job with the lowest avruntime. Contracted jobs are always
  dequeued before marketplace jobs (two-tier preemption).
  """
  @spec dequeue() :: {:ok, {queue_entry(), map()}} | :empty
  def dequeue do
    GenServer.call(__MODULE__, :dequeue)
  end

  @doc """
  Registers a client with their credit balance and priority level.
  """
  @spec register_client(client_id(), non_neg_integer(), priority()) :: :ok
  def register_client(client_id, credits, priority \\ :marketplace) do
    GenServer.call(__MODULE__, {:register_client, client_id, credits, priority})
  end

  @doc """
  Updates a client's credit balance (e.g., after purchasing credits or consuming them).
  """
  @spec update_credits(client_id(), non_neg_integer()) :: :ok
  def update_credits(client_id, new_credits) do
    GenServer.call(__MODULE__, {:update_credits, client_id, new_credits})
  end

  @doc """
  Returns the current scheduler state for introspection.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Returns the queue size.
  """
  @spec queue_size() :: non_neg_integer()
  def queue_size do
    GenServer.call(__MODULE__, :queue_size)
  end

  # -- Server Callbacks --

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      queue: :gb_trees.empty()
    }

    Logger.info("Scheduler started (reference_credits: #{state.reference_credits})")
    {:ok, state}
  end

  @impl true
  def handle_call({:register_client, client_id, credits, priority}, _from, state) do
    new_state =
      state
      |> put_in([Access.key(:client_credits), client_id], credits)
      |> put_in([Access.key(:client_priorities), client_id], priority)
      |> put_in([Access.key(:vruntimes), client_id], 0.0)

    Logger.info("Client #{client_id} registered (credits: #{credits}, priority: #{priority})")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:enqueue, client_id, job, _opts}, _from, state) do
    credits = Map.get(state.client_credits, client_id)

    cond do
      is_nil(credits) ->
        {:reply, {:error, :client_not_registered}, state}

      credits <= 0 ->
        {:reply, {:error, :insufficient_credits}, state}

      true ->
        vrt = Map.get(state.vruntimes, client_id, 0.0)
        priority = Map.get(state.client_priorities, client_id, :marketplace)

        # Use sequence number to break ties (FIFO within same vruntime)
        # Encode priority tier: contracted = 0, marketplace = 1
        # so contracted always sorts first
        tier = if priority == :contracted, do: 0, else: 1
        key = {tier, vrt, state.sequence}

        entry = %{
          client_id: client_id,
          job: job,
          priority: priority,
          enqueued_at: System.monotonic_time(:millisecond)
        }

        queue = :gb_trees.enter(key, entry, state.queue)

        new_state = %{state | queue: queue, sequence: state.sequence + 1}

        Logger.debug("Job enqueued for client #{client_id} (vrt: #{Float.round(vrt, 4)}, tier: #{priority})")
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:dequeue, _from, state) do
    case :gb_trees.size(state.queue) do
      0 ->
        {:reply, :empty, state}

      _ ->
        {key, entry, queue} = :gb_trees.take_smallest(state.queue)
        {_tier, _vrt, _seq} = key
        client_id = entry.client_id
        job = entry.job

        # Update avruntime for the client
        agent_cost = Map.get(job, :cost, 1.0)
        credits = Map.get(state.client_credits, client_id, state.reference_credits)
        priority = Map.get(state.client_priorities, client_id, :marketplace)
        weight = Map.get(@priority_weights, priority, 1.0)

        vrt_increment = agent_cost * state.reference_credits / (max(credits, 1) * weight)
        current_vrt = Map.get(state.vruntimes, client_id, 0.0)
        new_vrt = current_vrt + vrt_increment

        new_state =
          state
          |> Map.put(:queue, queue)
          |> put_in([Access.key(:vruntimes), client_id], new_vrt)
          |> Map.update!(:dispatched_count, &(&1 + 1))

        Logger.info("Dispatching job for client #{client_id} (new vrt: #{Float.round(new_vrt, 4)})")

        {:reply, {:ok, {key, entry}}, new_state}
    end
  end

  @impl true
  def handle_call({:update_credits, client_id, new_credits}, _from, state) do
    new_state = put_in(state, [Access.key(:client_credits), client_id], new_credits)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      queue_size: :gb_trees.size(state.queue),
      dispatched_count: state.dispatched_count,
      registered_clients: map_size(state.client_credits),
      vruntimes: state.vruntimes,
      client_credits: state.client_credits
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:queue_size, _from, state) do
    {:reply, :gb_trees.size(state.queue), state}
  end
end
