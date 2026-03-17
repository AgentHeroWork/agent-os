defmodule AgentScheduler.SchedulerTest do
  use ExUnit.Case, async: false

  alias AgentScheduler.Scheduler

  setup do
    # Scheduler may already be running from the application startup
    case start_supervised(Scheduler) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Drain any queued items from prior tests
    drain_queue()

    :ok
  end

  defp drain_queue do
    case Scheduler.dequeue() do
      {:ok, _} -> drain_queue()
      :empty -> :ok
    end
  end

  describe "client registration and enqueue" do
    test "enqueue fails for unregistered client" do
      job = %{id: "j1", task: :test, input: %{}}
      assert {:error, :client_not_registered} = Scheduler.enqueue("unknown_#{unique()}", job)
    end

    test "enqueue fails with zero credits" do
      id = "c_zero_#{unique()}"
      Scheduler.register_client(id, 0, :marketplace)
      job = %{id: "j1", task: :test, input: %{}}
      assert {:error, :insufficient_credits} = Scheduler.enqueue(id, job)
    end

    test "enqueue succeeds with credits" do
      id = "c_enqueue_#{unique()}"
      Scheduler.register_client(id, 100, :marketplace)
      job = %{id: "j1", task: :test, input: %{}}
      assert :ok = Scheduler.enqueue(id, job)
      assert Scheduler.queue_size() >= 1
    end
  end

  describe "priority and vruntime scheduling" do
    test "contracted jobs dequeue before marketplace" do
      contracted = "contracted_#{unique()}"
      market = "market_#{unique()}"
      Scheduler.register_client(contracted, 1000, :contracted)
      Scheduler.register_client(market, 1000, :marketplace)

      Scheduler.enqueue(market, %{id: "j_market", task: :test, input: %{}})
      Scheduler.enqueue(contracted, %{id: "j_contract", task: :test, input: %{}})

      {:ok, {_key, entry}} = Scheduler.dequeue()
      assert entry.client_id == contracted

      {:ok, {_key, entry2}} = Scheduler.dequeue()
      assert entry2.client_id == market
    end

    test "vruntime increases after dequeue" do
      id = "c_vruntime_#{unique()}"
      Scheduler.register_client(id, 500, :marketplace)
      Scheduler.enqueue(id, %{id: "j1", task: :test, input: %{}, cost: 10.0})

      stats_before = Scheduler.get_stats()
      assert stats_before.vruntimes[id] == 0.0

      Scheduler.dequeue()

      stats_after = Scheduler.get_stats()
      assert stats_after.vruntimes[id] > 0.0
    end

    test "higher credits = lower vruntime increment (fairness)" do
      rich = "rich_#{unique()}"
      poor = "poor_#{unique()}"
      Scheduler.register_client(rich, 10_000, :marketplace)
      Scheduler.register_client(poor, 100, :marketplace)

      Scheduler.enqueue(rich, %{id: "j1", task: :test, input: %{}, cost: 1.0})
      Scheduler.enqueue(poor, %{id: "j2", task: :test, input: %{}, cost: 1.0})

      Scheduler.dequeue()
      Scheduler.dequeue()

      stats = Scheduler.get_stats()
      assert stats.vruntimes[rich] < stats.vruntimes[poor]
    end

    test "empty queue returns :empty" do
      assert :empty = Scheduler.dequeue()
    end
  end

  describe "stats" do
    test "get_stats returns current state" do
      id = "c_stats_#{unique()}"
      Scheduler.register_client(id, 500, :marketplace)
      stats = Scheduler.get_stats()
      assert stats.registered_clients >= 1
      assert is_integer(stats.queue_size)
      assert is_integer(stats.dispatched_count)
    end
  end

  defp unique, do: :erlang.unique_integer([:positive])
end
