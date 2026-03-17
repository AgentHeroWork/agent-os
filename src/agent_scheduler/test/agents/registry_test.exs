defmodule AgentScheduler.Agents.RegistryTest do
  use ExUnit.Case, async: true

  alias AgentScheduler.Agents.Registry

  # A module that does NOT implement AgentType — used for validation tests.
  defmodule NotAnAgent do
    def hello, do: :world
  end

  # A module that implements AgentType — used for custom registration tests.
  defmodule FakeAgent do
    @behaviour AgentScheduler.Agents.AgentType

    @impl true
    def profile do
      %{
        name: "FakeAgent",
        capabilities: [:testing],
        task_domain: [:test],
        default_oversight: :supervised,
        description: "A fake agent for testing"
      }
    end

    @impl true
    def run_autonomous(_input, _context), do: {:ok, %{artifacts: %{}, metadata: %{}}}

    @impl true
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
    test "OpenClaw is auto-registered", %{registry: reg} do
      assert {:ok, AgentScheduler.Agents.OpenClaw} = Registry.lookup(:openclaw, reg)
    end

    test "NemoClaw is auto-registered", %{registry: reg} do
      assert {:ok, AgentScheduler.Agents.NemoClaw} = Registry.lookup(:nemoclaw, reg)
    end

    test "both types appear in list", %{registry: reg} do
      types = Registry.types(reg)
      assert :openclaw in types
      assert :nemoclaw in types
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
    test "returns {:ok, module} for a known type", %{registry: reg} do
      assert {:ok, AgentScheduler.Agents.OpenClaw} = Registry.lookup(:openclaw, reg)
    end

    test "returns {:error, :not_found} for an unknown type", %{registry: reg} do
      assert {:error, :not_found} = Registry.lookup(:unknown_agent, reg)
    end
  end

  describe "list/1" do
    test "returns all registered types as tuples", %{registry: reg} do
      list = Registry.list(reg)
      assert is_list(list)
      assert {:openclaw, AgentScheduler.Agents.OpenClaw} in list
      assert {:nemoclaw, AgentScheduler.Agents.NemoClaw} in list
    end

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
