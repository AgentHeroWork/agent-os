defmodule AgentOS.Contracts.LoaderTest do
  use ExUnit.Case, async: true

  alias AgentOS.Contracts.{Loader, ContractSpec}

  describe "load/1" do
    test "loads research-report contract" do
      assert {:ok, %ContractSpec{} = spec} = Loader.load("research-report")
      assert spec.name == "research-report"
      assert length(spec.stages) == 3
      assert :findings_md in spec.required_artifacts
      assert spec.max_retries == 2
    end

    test "loads market-dashboard contract" do
      assert {:ok, %ContractSpec{} = spec} = Loader.load("market-dashboard")
      assert spec.name == "market-dashboard"
      assert length(spec.stages) == 3
      assert spec.memory.knowledge_base == true
    end

    test "returns error for unknown contract" do
      assert {:error, {:contract_not_found, "nonexistent"}} = Loader.load("nonexistent")
    end
  end

  describe "list/0" do
    test "lists available contracts" do
      contracts = Loader.list()
      assert "research-report" in contracts
      assert "market-dashboard" in contracts
    end
  end
end
