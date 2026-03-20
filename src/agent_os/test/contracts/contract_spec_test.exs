defmodule AgentOS.Contracts.ContractSpecTest do
  use ExUnit.Case, async: true

  alias AgentOS.Contracts.ContractSpec

  describe "from_map/1" do
    test "builds spec from map with string keys" do
      map = %{
        "name" => "test-contract",
        "stages" => [
          %{"name" => "stage1", "instructions" => "do stuff", "output" => ["result.md"]}
        ],
        "required_artifacts" => ["result_md"],
        "max_retries" => 3
      }

      assert {:ok, %ContractSpec{} = spec} = ContractSpec.from_map(map)
      assert spec.name == "test-contract"
      assert length(spec.stages) == 1
      assert hd(spec.stages).name == :stage1
      assert spec.max_retries == 3
    end

    test "builds spec from map with atom keys" do
      map = %{
        name: "atom-contract",
        stages: [%{name: :s1, instructions: "work", output: ["out.md"]}],
        required_artifacts: [:out_md]
      }

      assert {:ok, %ContractSpec{}} = ContractSpec.from_map(map)
    end

    test "returns error for missing name" do
      assert {:error, {:missing_required, "name"}} = ContractSpec.from_map(%{})
    end

    test "pipeline? returns true when stages exist" do
      {:ok, spec} =
        ContractSpec.from_map(%{
          name: "test",
          stages: [%{name: "s1", instructions: "x", output: ["y"]}]
        })

      assert ContractSpec.pipeline?(spec)
    end

    test "pipeline? returns false when no stages" do
      {:ok, spec} = ContractSpec.from_map(%{name: "test"})
      refute ContractSpec.pipeline?(spec)
    end
  end
end
