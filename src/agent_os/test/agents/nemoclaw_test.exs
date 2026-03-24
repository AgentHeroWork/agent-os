defmodule AgentOS.Agents.NemoClawTest do
  use ExUnit.Case, async: true

  alias AgentOS.Agents.NemoClaw

  describe "profile/0" do
    test "returns restricted profile" do
      profile = NemoClaw.profile()
      assert profile.name == "NemoClaw"
      assert :web_search in profile.capabilities
      assert :memory in profile.capabilities
      # NemoClaw should NOT have shell, filesystem, or browser
      refute :shell in profile.capabilities
      refute :filesystem in profile.capabilities
      refute :browser in profile.capabilities
      assert profile.default_oversight == :supervised
    end
  end

  describe "tool_requirements/0" do
    test "requires only safe tools" do
      tools = NemoClaw.tool_requirements()
      assert "web-search" in tools
      assert "text-transform" in tools
      refute "shell-exec" in tools
      refute "file-ops" in tools
    end
  end

  describe "privacy_routing?/0" do
    test "always enabled" do
      assert NemoClaw.privacy_routing?() == true
    end
  end

  describe "guardrail enforcement" do
    setup do
      context = %{
        agent_id: "nemoclaw_test_1",
        job: %{task: :research},
        memory: %{},
        step_number: 0
      }

      {:ok, context: context}
    end

    test "blocks PII in input", %{context: ctx} do
      input = %{query: "find password for admin"}

      assert {:error, {:guardrail_blocked, :pii_detected}} =
               NemoClaw.execute_step("search", input, ctx)
    end

    test "blocks unapproved domains", %{context: ctx} do
      input = %{url: "https://evil-site.com/data"}

      assert {:error, {:guardrail_blocked, :domain_not_approved, _}} =
               NemoClaw.execute_step("search", input, ctx)
    end

    test "allows approved domains and sanitizes output", %{context: ctx} do
      # This test requires an LLM key since "search" now calls the LLM
      if System.get_env("OPENAI_API_KEY") || System.get_env("ANTHROPIC_API_KEY") do
        input = %{url: "https://arxiv.org/paper/123", topic: "physics"}
        {:ok, result} = NemoClaw.execute_step("search", input, ctx)
        assert result.privacy_routing == true
      end
    end

    test "analyze step passes through with guardrails", %{context: ctx} do
      input = %{topic: "safe topic", data: "test"}
      {:ok, result} = NemoClaw.execute_step("analyze", input, ctx)
      assert result.topic == "safe topic"
    end

    test "persist step sanitizes PII in output", %{context: ctx} do
      input = %{topic: "test", email_field: "user@example.com"}
      {:ok, result} = NemoClaw.execute_step("persist", input, ctx)
      assert result.privacy_routing == true
      # Email should be redacted in the sanitized data
      refute String.contains?(inspect(result.data), "user@example.com")
    end
  end

  describe "supervised oversight" do
    test "default oversight is :supervised" do
      assert NemoClaw.profile().default_oversight == :supervised
    end
  end
end
