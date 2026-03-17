defmodule AgentOS.AgentSpecTest do
  use ExUnit.Case, async: true

  alias AgentOS.AgentSpec

  describe "new/1" do
    test "creates a valid spec with required fields" do
      assert {:ok, spec} = AgentSpec.new(%{type: :open_claw, name: "test-agent"})

      assert spec.type == :open_claw
      assert spec.name == "test-agent"
      assert spec.oversight == :autonomous_escalation
      assert spec.provider == :local
    end

    test "returns error when type is missing" do
      assert {:error, {:missing_required, :type}} = AgentSpec.new(%{name: "test-agent"})
    end

    test "returns error when name is missing" do
      assert {:error, {:missing_required, :name}} = AgentSpec.new(%{type: :open_claw})
    end

    test "accepts optional overrides" do
      attrs = %{
        type: :nemo_claw,
        name: "custom-agent",
        oversight: :supervised,
        provider: :fly,
        metadata: %{region: "iad"}
      }

      assert {:ok, spec} = AgentSpec.new(attrs)
      assert spec.oversight == :supervised
      assert spec.provider == :fly
      assert spec.metadata == %{region: "iad"}
    end
  end

  describe "validate/1" do
    test "returns :ok for valid spec with satisfied credentials" do
      {:ok, spec} = AgentSpec.new(%{type: :open_claw, name: "test"})
      spec = %{spec | credentials: %{github_token: "ghp_test", agent_os_api_key: nil, fly_api_token: nil, custom: %{}}}

      assert AgentSpec.validate(spec) == :ok
    end

    test "returns error for unknown agent type" do
      {:ok, spec} = AgentSpec.new(%{type: :generic, name: "test"})
      spec = %{spec | type: :unknown_type}

      assert {:error, errors} = AgentSpec.validate(spec)
      assert Enum.any?(errors, fn {reason, _} -> reason == :unknown_agent_type end)
    end

    test "returns error for missing required credentials" do
      {:ok, spec} = AgentSpec.new(%{type: :open_claw, name: "test"})
      spec = %{spec | credentials: %{github_token: nil, agent_os_api_key: nil, fly_api_token: nil, custom: %{}}}

      assert {:error, errors} = AgentSpec.validate(spec)
      assert Enum.any?(errors, fn {reason, _} -> reason == :missing_credentials end)
    end
  end

  describe "defaults" do
    test "default completion pipeline is full" do
      {:ok, spec} = AgentSpec.new(%{type: :generic, name: "test"})

      assert spec.completion.pipeline == [
               :write_latex,
               :compile_pdf,
               :ensure_repo,
               :generate_readme,
               :push_artifacts
             ]
    end

    test "default provider is :local" do
      {:ok, spec} = AgentSpec.new(%{type: :generic, name: "test"})
      assert spec.provider == :local
    end

    test "default resources are set" do
      {:ok, spec} = AgentSpec.new(%{type: :generic, name: "test"})
      assert spec.resources.cpu == "shared-cpu-1x"
      assert spec.resources.memory == "256mb"
      assert spec.resources.timeout_ms == 1_800_000
    end
  end
end
