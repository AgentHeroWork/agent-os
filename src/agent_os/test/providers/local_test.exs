defmodule AgentOS.Providers.LocalTest do
  use ExUnit.Case, async: false

  alias AgentOS.Providers.Local

  @ets_table :local_deployments

  setup do
    # These processes may already be running from the application startup.
    # Only start them if they aren't already alive.
    maybe_start_supervised({Registry, keys: :unique, name: AgentScheduler.Registry})
    maybe_start_supervised(AgentScheduler.Supervisor)
    maybe_start_supervised(AgentScheduler.Agents.Registry)

    # Clean up ETS table between tests
    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete_all_objects(@ets_table)
    end

    :ok
  end

  defp maybe_start_supervised(child_spec) do
    case start_supervised(child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {{:already_started, pid}, _}} -> {:ok, pid}
      other -> other
    end
  end

  describe "create_agent/1" do
    test "creates an agent and returns a deployment with :pending status" do
      config = %{
        type: :test_agent,
        name: "TestAgent",
        oversight: :autonomous_escalation,
        env: %{},
        resources: %{}
      }

      assert {:ok, deployment} = Local.create_agent(config)
      assert deployment.provider == :local
      assert deployment.status == :pending
      assert is_binary(deployment.id)
      assert String.starts_with?(deployment.id, "local_")
      assert %DateTime{} = deployment.created_at
    end

    test "creates multiple agents with unique IDs" do
      config = %{type: :test_agent, name: "Agent", oversight: :supervised, env: %{}, resources: %{}}

      assert {:ok, d1} = Local.create_agent(config)
      assert {:ok, d2} = Local.create_agent(config)
      assert d1.id != d2.id
    end
  end

  describe "status/1" do
    test "returns status for an existing deployment" do
      config = %{type: :test_agent, name: "StatusAgent", oversight: :autonomous_escalation, env: %{}, resources: %{}}
      {:ok, deployment} = Local.create_agent(config)

      assert {:ok, status} = Local.status(deployment.id)
      assert status.id == deployment.id
      assert status.status == :pending
    end

    test "returns :not_found for unknown deployment" do
      Local.ensure_table()
      assert {:error, :not_found} = Local.status("nonexistent_id")
    end
  end

  describe "list_agents/0" do
    test "returns empty list when no agents exist" do
      Local.ensure_table()
      assert {:ok, []} = Local.list_agents()
    end

    test "returns all created agents" do
      config = %{type: :test_agent, name: "ListAgent", oversight: :autonomous_escalation, env: %{}, resources: %{}}

      {:ok, _d1} = Local.create_agent(config)
      {:ok, _d2} = Local.create_agent(config)

      assert {:ok, deployments} = Local.list_agents()
      assert length(deployments) == 2
    end
  end

  describe "start_agent/2 and stop_agent/1" do
    test "starts an agent and transitions to running status" do
      config = %{type: :test_agent, name: "StartStopAgent", oversight: :autonomous_escalation, env: %{}, resources: %{}}
      {:ok, deployment} = Local.create_agent(config)

      job_spec = %{id: "job_001", task: "test task"}
      assert {:ok, updated} = Local.start_agent(deployment.id, job_spec)
      assert updated.status == :running
    end

    test "stops a running agent" do
      config = %{type: :test_agent, name: "StopAgent", oversight: :autonomous_escalation, env: %{}, resources: %{}}
      {:ok, deployment} = Local.create_agent(config)

      {:ok, _} = Local.start_agent(deployment.id, %{id: "job_002", task: "work"})
      assert :ok = Local.stop_agent(deployment.id)

      {:ok, status} = Local.status(deployment.id)
      assert status.status == :stopped
    end
  end

  describe "destroy_agent/1" do
    test "destroys an agent and removes it from tracking" do
      config = %{type: :test_agent, name: "DestroyAgent", oversight: :autonomous_escalation, env: %{}, resources: %{}}
      {:ok, deployment} = Local.create_agent(config)

      assert :ok = Local.destroy_agent(deployment.id)
      assert {:error, :not_found} = Local.status(deployment.id)
    end

    test "destroying a nonexistent agent succeeds gracefully" do
      Local.ensure_table()
      assert :ok = Local.destroy_agent("nonexistent_agent")
    end
  end

  describe "logs/2" do
    test "returns log entries for a running agent" do
      config = %{type: :test_agent, name: "LogAgent", oversight: :autonomous_escalation, env: %{}, resources: %{}}
      {:ok, deployment} = Local.create_agent(config)

      assert {:ok, logs} = Local.logs(deployment.id)
      assert is_list(logs)
      assert length(logs) > 0
      assert Enum.all?(logs, &is_binary/1)
    end
  end
end
