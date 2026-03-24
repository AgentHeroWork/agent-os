defmodule AgentOS.Agents.OpenClawTest do
  use ExUnit.Case, async: true

  alias AgentOS.Agents.OpenClaw

  describe "profile/0" do
    test "returns correct profile" do
      profile = OpenClaw.profile()
      assert profile.name == "OpenClaw"
      assert :web_search in profile.capabilities
      assert :browser in profile.capabilities
      assert :filesystem in profile.capabilities
      assert :shell in profile.capabilities
      assert profile.default_oversight == :autonomous_escalation
    end
  end

  describe "tool_requirements/0" do
    test "requires full tool set" do
      tools = OpenClaw.tool_requirements()
      assert "web-search" in tools
      assert "web-scrape" in tools
      assert "shell-exec" in tools
      assert "file-ops" in tools
    end
  end

  describe "execute_step/3" do
    setup do
      context = %{
        agent_id: "openclaw_test_1",
        job: %{task: :research, input: %{topic: "CERN"}},
        memory: %{},
        step_number: 0
      }

      {:ok, context: context}
    end

    test "plan step calls LLM and returns topic + plan", %{context: ctx} do
      # Skip if no LLM API key available (unit test environment)
      if System.get_env("OPENAI_API_KEY") || System.get_env("ANTHROPIC_API_KEY") do
        {:ok, result} = OpenClaw.execute_step("plan", %{topic: "particle physics"}, ctx)
        assert result.topic == "particle physics"
        assert is_binary(result.plan)
        assert String.length(result.plan) > 100
      end
    end

    test "analyze step passes through input", %{context: ctx} do
      {:ok, result} = OpenClaw.execute_step("analyze", %{data: "test"}, ctx)
      assert result.data == "test"
    end

    test "synthesize step passes through input", %{context: ctx} do
      {:ok, result} = OpenClaw.execute_step("synthesize", %{findings: ["f1"]}, ctx)
      assert result.findings == ["f1"]
    end

    test "persist step passes through input", %{context: ctx} do
      {:ok, result} = OpenClaw.execute_step("persist", %{data: "test"}, ctx)
      assert result.data == "test"
    end

    test "unknown step returns error", %{context: ctx} do
      assert {:error, {:unknown_step, "invalid"}} = OpenClaw.execute_step("invalid", %{}, ctx)
    end
  end
end
