defmodule AgentScheduler.Agents.RegistryTest do
  use ExUnit.Case, async: true

  alias AgentScheduler.Agents.Registry

  # A module that does NOT implement AgentType — used for validation tests.
  defmodule NotAnAgent do
    def hello, do: :world
  end

  # A module that implements the required callbacks for AgentType.
  defmodule FakeAgent do
    def profile do
      %{
        name: "FakeAgent",
        capabilities: [:testing],
        task_domain: [:test],
        default_oversight: :supervised,
        description: "A fake agent for testing"
      }
    end

    def run_autonomous(_input, _context), do: {:ok, %{artifacts: %{}, metadata: %{}}}

    def tool_requirements, do: []
  end

  setup do
    # Start a fresh registry for each test with a unique name
    name = :"registry_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Registry.start_link(name: name)
    {:ok, registry: name, pid: pid}
  end

  describe "start_link/1" do
    test "starts the registry GenServer", %{pid: pid} do
      assert Process.alive?(pid)
    end
  end

  describe "auto-registration on init" do
    test "auto-registers agent types when modules are available", %{registry: reg} do
      # When AgentOS.Agents.OpenClaw and NemoClaw are available (loaded via agent_os dep),
      # they will be auto-registered. When running standalone, they are skipped.
      types = Registry.types(reg)

      if Code.ensure_loaded?(AgentOS.Agents.OpenClaw) do
        assert :openclaw in types
        assert {:ok, AgentOS.Agents.OpenClaw} = Registry.lookup(:openclaw, reg)
      end

      if Code.ensure_loaded?(AgentOS.Agents.NemoClaw) do
        assert :nemoclaw in types
        assert {:ok, AgentOS.Agents.NemoClaw} = Registry.lookup(:nemoclaw, reg)
      end
    end
  end

  describe "register/3" do
    test "registers a valid agent type", %{registry: reg} do
      assert :ok = Registry.register(:fake, FakeAgent, reg)
      assert {:ok, FakeAgent} = Registry.lookup(:fake, reg)
    end

    test "rejects a module that does not implement AgentType", %{registry: reg} do
      assert {:error, {:missing_callbacks, missing}} = Registry.register(:bad, NotAnAgent, reg)
      assert :profile in missing
      assert :run_autonomous in missing
      assert :tool_requirements in missing
    end

    test "overwrites an existing registration", %{registry: reg} do
      assert :ok = Registry.register(:custom, FakeAgent, reg)
      assert {:ok, FakeAgent} = Registry.lookup(:custom, reg)
    end
  end

  describe "unregister/2" do
    test "removes a registered agent type", %{registry: reg} do
      assert :ok = Registry.register(:temp, FakeAgent, reg)
      assert {:ok, FakeAgent} = Registry.lookup(:temp, reg)

      assert :ok = Registry.unregister(:temp, reg)
      assert {:error, :not_found} = Registry.lookup(:temp, reg)
    end

    test "unregistering a non-existent type is a no-op", %{registry: reg} do
      assert :ok = Registry.unregister(:nonexistent, reg)
    end
  end

  describe "lookup/2" do
    test "returns {:ok, module} for a registered type", %{registry: reg} do
      assert :ok = Registry.register(:test_agent, FakeAgent, reg)
      assert {:ok, FakeAgent} = Registry.lookup(:test_agent, reg)
    end

    test "returns {:error, :not_found} for an unknown type", %{registry: reg} do
      assert {:error, :not_found} = Registry.lookup(:unknown_agent, reg)
    end
  end

  describe "list/1" do
    test "includes newly registered types", %{registry: reg} do
      Registry.register(:fake, FakeAgent, reg)
      list = Registry.list(reg)
      assert {:fake, FakeAgent} in list
    end
  end

  describe "types/1" do
    test "returns sorted list of type atoms", %{registry: reg} do
      types = Registry.types(reg)
      assert types == Enum.sort(types)
    end

    test "reflects registrations and unregistrations", %{registry: reg} do
      Registry.register(:alpha, FakeAgent, reg)
      assert :alpha in Registry.types(reg)

      Registry.unregister(:alpha, reg)
      refute :alpha in Registry.types(reg)
    end
  end
end
