defmodule AgentOS.Agents.CompletionHandler do
  @moduledoc """
  Utility toolkit for agent work product generation.

  Provides composable functions that agents call directly during autonomous
  execution: LaTeX generation, PDF compilation, GitHub repo management,
  README generation, and artifact pushing.

  Agents own their pipeline — this module provides the building blocks.
  """

  require Logger

  @default_output_dir "/tmp/agent-os/artifacts"
  @github_org "AgentHeroWork"

  # -- LaTeX Generation --

  @doc """
  Generates a LaTeX research paper from the agent's result.

  Returns `{:ok, tex_path}` where the .tex file was written.
  """
  @spec write_latex(map(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_latex(result, agent_profile, output_dir) do
    File.mkdir_p!(output_dir)

    agent_name = Map.get(agent_profile, :name, "Agent")
    topic = extract_topic(result)
    content = extract_content(result)
    abstract = extract_abstract(result)
    references = extract_references(result)
    date = Date.utc_today() |> Date.to_string()

    latex = """
    \\documentclass{article}
    \\usepackage[utf8]{inputenc}
    \\usepackage[T1]{fontenc}
    \\usepackage{hyperref}
    \\usepackage{amsmath}
    \\usepackage{amssymb}
    \\usepackage{graphicx}

    \\title{#{escape_latex(topic)}}
    \\author{#{escape_latex(agent_name)}}
    \\date{#{date}}

    \\begin{document}

    \\maketitle

    \\begin{abstract}
    #{sanitize_latex_content(abstract)}
    \\end{abstract}

    #{sanitize_latex_content(content)}

    \\section*{References}
    #{format_references(references)}

    \\end{document}
    """

    filename = slugify(topic) <> ".tex"
    tex_path = Path.join(output_dir, filename)

    case File.write(tex_path, latex) do
      :ok ->
        Logger.info("Wrote LaTeX to #{tex_path}")
        {:ok, tex_path}

      {:error, reason} ->
        {:error, {:write_failed, tex_path, reason}}
    end
  end

  # -- PDF Compilation --

  @doc """
  Compiles a .tex file to PDF using tectonic (preferred) or pdflatex as fallback.

  Returns `{:ok, pdf_path}` or `{:error, :compilation_failed}`.
  """
  @spec compile_pdf(String.t()) :: {:ok, String.t()} | {:error, :compilation_failed}
  def compile_pdf(tex_path) do
    output_dir = Path.dirname(tex_path)

    case try_tectonic(tex_path, output_dir) do
      {:ok, pdf_path} ->
        {:ok, pdf_path}

      {:error, _} ->
        case try_pdflatex(tex_path, output_dir) do
          {:ok, pdf_path} ->
            {:ok, pdf_path}

          {:error, _} ->
            Logger.error("PDF compilation failed for #{tex_path} (tried tectonic and pdflatex)")
            {:error, :compilation_failed}
        end
    end
  end

  # -- GitHub Repo Management --

  @doc """
  Ensures a GitHub repository exists for the agent's work product.

  Repo naming convention: `AgentHeroWork/{agent_type}-{topic_slug}-research`

  Returns `{:ok, repo_url}`.
  """
  @spec ensure_repo(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_repo(agent_profile, topic) do
    agent_type = agent_profile |> Map.get(:name, "agent") |> String.downcase()
    topic_slug = slugify(topic)
    repo_name = "#{agent_type}-#{topic_slug}-research"
    repo_url = "https://github.com/#{@github_org}/#{repo_name}"

    case System.cmd("gh", ["repo", "view", "#{@github_org}/#{repo_name}"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Logger.info("Repo already exists: #{repo_url}")
        {:ok, repo_url}

      {_, _} ->
        case System.cmd(
               "gh",
               [
                 "repo",
                 "create",
                 "#{@github_org}/#{repo_name}",
                 "--public",
                 "--description",
                 "Research artifacts by #{Map.get(agent_profile, :name, "Agent")}"
               ],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            Logger.info("Created repo: #{repo_url}")
            {:ok, repo_url}

          {output, _} ->
            Logger.error("Failed to create repo #{repo_name}: #{output}")
            {:error, {:repo_creation_failed, output}}
        end
    end
  end

  # -- README Generation --

  @doc """
  Generates a README.md with agent attribution and research summary.
  """
  @spec generate_readme(map(), map(), String.t()) :: String.t()
  def generate_readme(agent_profile, result, repo_url) do
    agent_name = Map.get(agent_profile, :name, "Agent")
    agent_type = Map.get(agent_profile, :name, "Unknown")
    description = Map.get(agent_profile, :description, "An AI research agent")
    topic = extract_topic(result)
    summary = extract_abstract(result)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    # #{topic}

    ## Agent Attribution

    | Field | Value |
    |-------|-------|
    | **Agent Name** | #{agent_name} |
    | **Agent Type** | #{agent_type} |
    | **Description** | #{description} |
    | **Generated** | #{timestamp} |

    ## Research Summary

    #{summary}

    ## About

    This research was generated by [#{agent_name}](https://github.com/#{@github_org}/agent-os) as part of the Agent OS platform.

    - **Repository**: #{repo_url}
    - **Agent OS**: [https://github.com/#{@github_org}/agent-os](https://github.com/#{@github_org}/agent-os)

    ---

    *Generated by Agent OS on #{timestamp}*
    """
  end

  # -- Artifact Pushing --

  @doc """
  Pushes artifacts (.tex, .pdf, README.md) to the GitHub repository.
  """
  @spec push_artifacts(String.t(), [String.t()], String.t()) :: :ok | {:error, term()}
  def push_artifacts(repo_url, file_paths, readme_content) do
    work_dir = System.tmp_dir!() |> Path.join("agent-os-push-#{:erlang.unique_integer([:positive])}")

    with {_, 0} <- System.cmd("git", ["clone", repo_url, work_dir], stderr_to_stdout: true) do
      # Write README
      readme_path = Path.join(work_dir, "README.md")
      File.write!(readme_path, readme_content)

      # Copy artifact files
      Enum.each(file_paths, fn path ->
        if path && File.exists?(path) do
          dest = Path.join(work_dir, Path.basename(path))
          File.cp!(path, dest)
        end
      end)

      # Git add, commit, push
      git_opts = [cd: work_dir, stderr_to_stdout: true]

      with {_, 0} <- System.cmd("git", ["add", "."], git_opts),
           {_, 0} <-
             System.cmd("git", ["commit", "-m", "Add research artifacts"], git_opts),
           {_, 0} <- System.cmd("git", ["push", "origin", "main"], git_opts) do
        File.rm_rf!(work_dir)
        Logger.info("Pushed artifacts to #{repo_url}")
        :ok
      else
        {output, _} ->
          File.rm_rf!(work_dir)
          Logger.error("Git push failed: #{output}")
          {:error, {:push_failed, output}}
      end
    else
      {output, _} ->
        Logger.error("Git clone failed: #{output}")
        {:error, {:clone_failed, output}}
    end
  end

  # -- Text Utilities (Public) --

  @doc """
  Reads LaTeX compilation error lines from the .log file.
  """
  @spec read_latex_errors(String.t()) :: String.t()
  def read_latex_errors(tex_path) do
    log_path = Path.rootname(tex_path) <> ".log"

    case File.read(log_path) do
      {:ok, log} ->
        log
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "!"))
        |> Enum.take(10)
        |> Enum.join("\n")

      _ ->
        "No error log available"
    end
  end

  @doc """
  Aggressively sanitizes LaTeX content by escaping all problematic characters.
  Used as a last-resort fallback when LLM fixes fail.
  """
  @spec aggressive_sanitize(String.t()) :: String.t()
  def aggressive_sanitize(content) do
    content
    |> String.replace(~r/(?<!\\)&/, "\\&")
    |> String.replace(~r/(?<!\\)#/, "\\#")
    |> String.replace(~r/(?<!\\)%/, "\\%")
    |> String.replace("*", "")
    |> String.replace(~r/(?<!\\)_(?![a-zA-Z]*\{)/, "\\_")
  end

  @doc false
  @spec extract_topic(map()) :: String.t()
  def extract_topic(result) do
    Map.get(result, :topic, Map.get(result, "topic", "Untitled Research"))
  end

  @doc false
  @spec sanitize_latex_content(String.t()) :: String.t()
  def sanitize_latex_content(text) when is_binary(text) do
    text
    |> String.replace("&", "\\&")
    |> String.replace("#", "\\#")
    |> String.replace("*", "")
    |> String.replace("\\\\&", "\\&")
    |> String.replace("\\\\#", "\\#")
  end

  def sanitize_latex_content(other), do: to_string(other)

  @doc false
  @spec escape_latex(String.t()) :: String.t()
  def escape_latex(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\textbackslash{}")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
    |> String.replace("&", "\\&")
    |> String.replace("%", "\\%")
    |> String.replace("$", "\\$")
    |> String.replace("#", "\\#")
    |> String.replace("_", "\\_")
    |> String.replace("~", "\\textasciitilde{}")
    |> String.replace("^", "\\textasciicircum{}")
  end

  def escape_latex(other), do: to_string(other)

  @doc false
  @spec slugify(String.t()) :: String.t()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 50)
  end

  def slugify(_), do: "untitled"

  @doc """
  Returns the default output directory for agent artifacts.
  """
  @spec default_output_dir() :: String.t()
  def default_output_dir, do: @default_output_dir

  # -- Private Helpers --

  defp extract_content(result) do
    Map.get(
      result,
      :content,
      Map.get(result, "content", Map.get(result, :summary, Map.get(result, "summary", "")))
    )
  end

  defp extract_abstract(result) do
    Map.get(
      result,
      :abstract,
      Map.get(result, "abstract", Map.get(result, :summary, Map.get(result, "summary", "No abstract available.")))
    )
  end

  defp extract_references(result) do
    Map.get(result, :references, Map.get(result, "references", []))
  end

  defp format_references([]), do: "No references cited."

  defp format_references(references) when is_list(references) do
    references
    |> Enum.with_index(1)
    |> Enum.map(fn {ref, idx} ->
      "[#{idx}] #{sanitize_latex_content(to_string(ref))}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_references(_), do: "No references cited."

  defp try_tectonic(tex_path, output_dir) do
    case System.cmd("tectonic", [tex_path, "-o", output_dir], stderr_to_stdout: true) do
      {_, 0} ->
        pdf_path = tex_path |> Path.rootname() |> Kernel.<>(".pdf")
        {:ok, pdf_path}

      {output, _} ->
        Logger.warning("tectonic failed: #{String.slice(output, 0, 200)}")
        {:error, :tectonic_failed}
    end
  rescue
    e ->
      Logger.warning("tectonic not available: #{Exception.message(e)}")
      {:error, :tectonic_not_found}
  end

  defp try_pdflatex(tex_path, output_dir) do
    case System.cmd(
           "pdflatex",
           ["-interaction=nonstopmode", "-halt-on-error", "-output-directory", output_dir, tex_path],
           stderr_to_stdout: true,
           env: [{"max_print_line", "1000"}]
         ) do
      {_, 0} ->
        pdf_path = tex_path |> Path.rootname() |> Kernel.<>(".pdf")
        {:ok, pdf_path}

      {output, _} ->
        Logger.warning("pdflatex failed: #{String.slice(output, 0, 200)}")
        {:error, :pdflatex_failed}
    end
  rescue
    e ->
      Logger.warning("pdflatex not available: #{Exception.message(e)}")
      {:error, :pdflatex_not_found}
  end
end
