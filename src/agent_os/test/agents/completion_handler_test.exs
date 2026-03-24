defmodule AgentOS.Agents.CompletionHandlerTest do
  use ExUnit.Case, async: true

  alias AgentOS.Agents.CompletionHandler

  @sample_profile %{
    name: "OpenClaw",
    capabilities: [:web_search, :browser, :filesystem, :shell, :memory],
    task_domain: [:research, :analysis],
    default_oversight: :autonomous_escalation,
    description: "Full-capability autonomous research agent"
  }

  @sample_result %{
    topic: "Quantum Computing Advances",
    abstract: "A survey of recent advances in quantum computing hardware and algorithms.",
    content: "Quantum computing has seen significant progress in recent years.",
    summary: "Key developments in superconducting qubits and error correction.",
    references: [
      "Arute et al., Nature 574, 505-510 (2019)",
      "Preskill, Quantum 2, 79 (2018)"
    ]
  }

  setup do
    # Use a unique temp dir for each test to avoid conflicts
    test_dir = Path.join(System.tmp_dir!(), "agent-os-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, output_dir: test_dir}
  end

  describe "write_latex/3" do
    test "generates a valid LaTeX string with document structure", %{output_dir: dir} do
      {:ok, tex_path} = CompletionHandler.write_latex(@sample_result, @sample_profile, dir)

      assert String.ends_with?(tex_path, ".tex")
      assert File.exists?(tex_path)

      content = File.read!(tex_path)
      assert content =~ "\\documentclass{article}"
      assert content =~ "\\begin{document}"
      assert content =~ "\\end{document}"
      assert content =~ "\\maketitle"
    end

    test "includes agent name as author", %{output_dir: dir} do
      {:ok, tex_path} = CompletionHandler.write_latex(@sample_result, @sample_profile, dir)
      content = File.read!(tex_path)
      assert content =~ "\\author{OpenClaw}"
    end

    test "includes the topic as title", %{output_dir: dir} do
      {:ok, tex_path} = CompletionHandler.write_latex(@sample_result, @sample_profile, dir)
      content = File.read!(tex_path)
      assert content =~ "Quantum Computing Advances"
    end

    test "includes abstract section", %{output_dir: dir} do
      {:ok, tex_path} = CompletionHandler.write_latex(@sample_result, @sample_profile, dir)
      content = File.read!(tex_path)
      assert content =~ "\\begin{abstract}"
      assert content =~ "recent advances in quantum computing"
    end

    test "includes references", %{output_dir: dir} do
      {:ok, tex_path} = CompletionHandler.write_latex(@sample_result, @sample_profile, dir)
      content = File.read!(tex_path)
      assert content =~ "References"
      assert content =~ "Arute et al"
    end

    test "generates filename from topic slug", %{output_dir: dir} do
      {:ok, tex_path} = CompletionHandler.write_latex(@sample_result, @sample_profile, dir)
      filename = Path.basename(tex_path)
      assert filename == "quantum-computing-advances.tex"
    end

    test "handles result with minimal data", %{output_dir: dir} do
      minimal_result = %{topic: "Test"}
      {:ok, tex_path} = CompletionHandler.write_latex(minimal_result, @sample_profile, dir)
      assert tex_path != nil
      assert File.exists?(tex_path)
    end
  end

  describe "generate_readme/3" do
    test "includes agent name" do
      readme = CompletionHandler.generate_readme(@sample_profile, @sample_result, "https://github.com/test/repo")
      assert readme =~ "OpenClaw"
    end

    test "includes agent description" do
      readme = CompletionHandler.generate_readme(@sample_profile, @sample_result, "https://github.com/test/repo")
      assert readme =~ "Full-capability autonomous research agent"
    end

    test "includes research topic as heading" do
      readme = CompletionHandler.generate_readme(@sample_profile, @sample_result, "https://github.com/test/repo")
      assert readme =~ "# Quantum Computing Advances"
    end

    test "includes research summary" do
      readme = CompletionHandler.generate_readme(@sample_profile, @sample_result, "https://github.com/test/repo")
      assert readme =~ "recent advances in quantum computing"
    end

    test "includes link to agent-os" do
      readme = CompletionHandler.generate_readme(@sample_profile, @sample_result, "https://github.com/test/repo")
      assert readme =~ "https://github.com/AgentHeroWork/agent-os"
    end

    test "includes repo URL" do
      repo_url = "https://github.com/AgentHeroWork/openclaw-quantum-research"
      readme = CompletionHandler.generate_readme(@sample_profile, @sample_result, repo_url)
      assert readme =~ repo_url
    end

    test "includes generation timestamp" do
      readme = CompletionHandler.generate_readme(@sample_profile, @sample_result, "https://github.com/test/repo")
      assert readme =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end
  end

  describe "escape_latex/1" do
    test "escapes special LaTeX characters" do
      assert CompletionHandler.escape_latex("100% done") =~ "\\%"
      assert CompletionHandler.escape_latex("cost $5") =~ "\\$"
      assert CompletionHandler.escape_latex("A & B") =~ "\\&"
      assert CompletionHandler.escape_latex("item #1") =~ "\\#"
      assert CompletionHandler.escape_latex("under_score") =~ "\\_"
    end
  end

  describe "slugify/1" do
    test "converts text to URL-friendly slug" do
      assert CompletionHandler.slugify("Quantum Computing Advances") == "quantum-computing-advances"
    end

    test "removes special characters" do
      assert CompletionHandler.slugify("Hello, World! (2024)") == "hello-world-2024"
    end

    test "handles empty or nil input" do
      assert CompletionHandler.slugify("") == ""
      assert CompletionHandler.slugify(nil) == "untitled"
    end
  end

  describe "read_latex_errors/1" do
    test "returns 'No error log available' when no log exists", %{output_dir: dir} do
      assert CompletionHandler.read_latex_errors(Path.join(dir, "nonexistent.tex")) ==
               "No error log available"
    end

    test "extracts error lines from log file", %{output_dir: dir} do
      log_path = Path.join(dir, "test.log")
      File.write!(log_path, "Some info\n! Undefined control sequence.\n! Missing $ inserted.\nMore info\n")

      errors = CompletionHandler.read_latex_errors(Path.join(dir, "test.tex"))
      assert errors =~ "Undefined control sequence"
      assert errors =~ "Missing $ inserted"
    end
  end

  describe "aggressive_sanitize/1" do
    test "escapes unescaped special characters" do
      result = CompletionHandler.aggressive_sanitize("A & B # C % D")
      assert result =~ "\\&"
      assert result =~ "\\#"
      assert result =~ "\\%"
    end

    test "does not double-escape already escaped characters" do
      result = CompletionHandler.aggressive_sanitize("\\& already escaped")
      refute result =~ "\\\\&"
    end
  end
end
