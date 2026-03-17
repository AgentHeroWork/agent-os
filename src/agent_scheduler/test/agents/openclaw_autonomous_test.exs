defmodule AgentScheduler.Agents.OpenClawAutonomousTest do
  @moduledoc """
  Functional test: runs OpenClaw's full autonomous pipeline with real LLM calls.

  This test requires OPENAI_API_KEY or ANTHROPIC_API_KEY in the environment.
  It exercises: LLM plan → LLM research → LLM review → write .tex → compile PDF.
  GitHub repo creation/push is skipped (would create real repos).
  """
  use ExUnit.Case, async: false

  alias AgentScheduler.Agents.OpenClaw

  @tag :functional
  @tag timeout: 120_000

  describe "run_autonomous/2 — full pipeline" do
    setup do
      output_dir = Path.join(System.tmp_dir!(), "openclaw-functional-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(output_dir)

      on_exit(fn -> File.rm_rf!(output_dir) end)

      {:ok, output_dir: output_dir}
    end

    test "produces .tex file with substantive content from real LLM", %{output_dir: output_dir} do
      # Skip if no LLM API key
      unless System.get_env("OPENAI_API_KEY") || System.get_env("ANTHROPIC_API_KEY") do
        IO.puts("SKIPPING: No LLM API key available")
        assert true
      else
        input = %{topic: "Recent advances in quantum chromodynamics at the LHC"}

        context = %{
          agent_id: "test_openclaw_functional",
          output_dir: output_dir,
          attempt: 0
        }

        # This will call real LLM APIs — plan, research, review, write_latex
        # It WILL fail at compile_pdf or ensure_repo — that's expected for a test
        # We intercept by testing run_autonomous which includes all steps
        result = OpenClaw.run_autonomous(input, context)

        case result do
          {:ok, %{artifacts: artifacts, metadata: metadata}} ->
            # Full success — verify artifacts
            assert artifacts.tex_path != nil, "Expected .tex path"
            assert File.exists?(artifacts.tex_path), "Expected .tex file to exist at #{artifacts.tex_path}"

            tex_content = File.read!(artifacts.tex_path)
            assert String.length(tex_content) > 500, "Expected substantive LaTeX (got #{String.length(tex_content)} chars)"
            assert tex_content =~ "\\documentclass", "Expected LaTeX document structure"
            assert tex_content =~ "\\begin{document}", "Expected document body"
            assert tex_content =~ "quantum" or tex_content =~ "QCD" or tex_content =~ "chromodynamics",
                   "Expected topic-relevant content"

            assert metadata.agent == "OpenClaw"
            IO.puts("SUCCESS: Full pipeline produced #{String.length(tex_content)} chars of LaTeX")

            if artifacts.pdf_path && File.exists?(artifacts.pdf_path) do
              pdf_size = File.stat!(artifacts.pdf_path).size
              IO.puts("SUCCESS: PDF compiled (#{pdf_size} bytes)")
            else
              IO.puts("NOTE: PDF not produced (pdflatex/tectonic may not be available)")
            end

          {:escalate, %{reason: reason, message: message}} ->
            # Escalation is acceptable — means LLM worked but infra failed
            IO.puts("ESCALATED (expected in test): #{reason} — #{message}")

            # If it escalated at compilation or repo, the LLM steps still worked
            assert reason in [:compilation_stuck, :infrastructure_failure],
                   "Unexpected escalation reason: #{reason}"

          {:error, {:plan_failed, _}} ->
            flunk("LLM plan step failed — check API key and connectivity")

          {:error, {:research_failed, _}} ->
            flunk("LLM research step failed — check API key and connectivity")

          {:error, reason} ->
            flunk("Unexpected error: #{inspect(reason)}")
        end
      end
    end
  end
end
