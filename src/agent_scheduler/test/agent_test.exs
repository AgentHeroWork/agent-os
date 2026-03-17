defmodule AgentScheduler.AgentTest do
  use ExUnit.Case, async: false

  alias AgentScheduler.Agent

  setup do
    # Registry may already be running from the application startup
    case start_supervised({Registry, keys: :unique, name: AgentScheduler.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    agent_id = "test_agent_#{:erlang.unique_integer([:positive])}"

    profile = %{
      name: "TestAgent",
      capabilities: [:web_search, :shell],
      task_domain: [:research],
      input_schema: %{},
      output_schema: %{}
    }

    {:ok, agent_id: agent_id, profile: profile}
  end

  describe "lifecycle: pending → running → completed" do
    test "starts in pending state", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile)
      {:ok, state} = Agent.get_state(id)
      assert state.state == :pending
      assert state.id == id
    end

    test "assign_job transitions to running", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile)
      job = %{id: "job_1", task: :research, input: %{topic: "CERN"}}
      assert :ok = Agent.assign_job(id, job)
      {:ok, state} = Agent.get_state(id)
      assert state.state == :running
      assert state.current_job == job
    end

    test "complete transitions to completed", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile)
      Agent.assign_job(id, %{id: "job_1", task: :test})
      assert :ok = Agent.complete(id, %{output: "done"})
      {:ok, state} = Agent.get_state(id)
      assert state.state == :completed
    end

    test "execute_step with memoization", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile)
      Agent.assign_job(id, %{id: "job_1", task: :test})

      # First execution
      {:ok, result} = Agent.execute_step(id, "step_1", fn -> 42 end)
      assert result == 42

      # Memoized replay — function is not called again
      {:ok, cached} = Agent.execute_step(id, "step_1", fn -> raise "should not run" end)
      assert cached == 42

      {:ok, state} = Agent.get_state(id)
      assert state.metrics.steps_completed == 1
      assert state.metrics.steps_cached == 1
    end
  end

  describe "lifecycle: failure paths" do
    test "assign_job fails when not pending", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile)
      Agent.assign_job(id, %{id: "job_1", task: :test})

      assert {:error, {:invalid_state, :running, :expected, [:pending]}} =
               Agent.assign_job(id, %{id: "job_2", task: :test})
    end

    test "cancel transitions to cancelled", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile)
      Agent.assign_job(id, %{id: "job_1", task: :test})
      Agent.cancel(id)
      # cast is async, give it a moment
      Process.sleep(50)
      {:ok, state} = Agent.get_state(id)
      assert state.state == :cancelled
    end

    test "checkpoint and resume", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile)
      Agent.assign_job(id, %{id: "job_1", task: :test})
      Agent.execute_step(id, "s1", fn -> :result end)

      assert :ok = Agent.checkpoint(id)
      {:ok, state} = Agent.get_state(id)
      assert state.state == :checkpointed
      assert state.checkpoint_data.memo_store == %{"s1" => :result}

      # Can still execute steps from checkpointed state
      {:ok, val} = Agent.execute_step(id, "s2", fn -> :another end)
      assert val == :another
    end
  end

  describe "oversight modes" do
    test "supervised mode requires approval", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile, oversight: :supervised)
      Agent.assign_job(id, %{id: "job_1", task: :test})

      assert :ok = Agent.request_approval(id, %{artifact: "test"})
      {:ok, state} = Agent.get_state(id)
      assert state.state == :waiting_approval

      assert :ok = Agent.respond_approval(id, :approve)
      {:ok, state} = Agent.get_state(id)
      assert state.state == :running
    end

    test "rejection with retry", %{agent_id: id, profile: profile} do
      {:ok, _pid} = Agent.start_link(id: id, profile: profile, oversight: :supervised, max_retries: 1)
      Agent.assign_job(id, %{id: "job_1", task: :test})

      Agent.request_approval(id, %{artifact: "test"})
      Agent.respond_approval(id, :reject, "needs work")
      {:ok, state} = Agent.get_state(id)
      assert state.state == :pending
      assert state.retry_count == 1

      # Retry
      Agent.assign_job(id, %{id: "job_1", task: :test})
      Agent.request_approval(id, %{artifact: "test2"})
      Agent.respond_approval(id, :reject, "still bad")
      {:ok, state} = Agent.get_state(id)
      assert state.state == :failed
    end
  end
end
