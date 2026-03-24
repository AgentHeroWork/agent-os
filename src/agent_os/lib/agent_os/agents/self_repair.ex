defmodule AgentOS.Agents.SelfRepair do
  @moduledoc """
  Shared LLM-powered self-repair for LaTeX compilation.

  Agents call `compile_pdf_with_fix/2` to compile a .tex file with automatic
  error detection, LLM-driven fixes, and aggressive sanitization fallback.
  """

  require Logger

  alias AgentOS.Agents.CompletionHandler

  @max_fix_attempts 3

  @doc """
  Compiles a .tex file to PDF, using LLM to fix errors on failure.

  Tries up to #{@max_fix_attempts} LLM fix attempts, then falls back to
  aggressive sanitization. Returns `{:ok, pdf_path}` or
  `{:error, :compilation_exhausted}`.

  ## Options
    * `:model` — LLM model for fix suggestions (default: "gpt-4o")
    * `:max_tokens` — Max tokens for fix response (default: 8192)
    * `:temperature` — Sampling temperature (default: 0.2)
  """
  @spec compile_pdf_with_fix(String.t(), keyword()) :: {:ok, String.t()} | {:error, :compilation_exhausted}
  def compile_pdf_with_fix(tex_path, llm_opts \\ []) do
    do_compile(tex_path, llm_opts, 0)
  end

  defp do_compile(tex_path, _llm_opts, attempt) when attempt >= @max_fix_attempts do
    Logger.warning("SelfRepair: fix attempts exhausted — trying aggressive sanitize fallback")

    case File.read(tex_path) do
      {:ok, content} ->
        safe_content = CompletionHandler.aggressive_sanitize(content)
        File.write!(tex_path, safe_content)

        case CompletionHandler.compile_pdf(tex_path) do
          {:ok, pdf_path} -> {:ok, pdf_path}
          _ -> {:error, :compilation_exhausted}
        end

      _ ->
        {:error, :compilation_exhausted}
    end
  end

  defp do_compile(tex_path, llm_opts, attempt) do
    case CompletionHandler.compile_pdf(tex_path) do
      {:ok, pdf_path} ->
        {:ok, pdf_path}

      {:error, _} ->
        Logger.info("SelfRepair: PDF compilation failed — asking LLM to fix (attempt #{attempt + 1}/#{@max_fix_attempts})")
        error_log = CompletionHandler.read_latex_errors(tex_path)
        tex_content = File.read!(tex_path)

        case fix_latex_via_llm(tex_content, error_log, llm_opts) do
          {:ok, fixed_content} ->
            File.write!(tex_path, fixed_content)
            do_compile(tex_path, llm_opts, attempt + 1)

          {:error, _} ->
            do_compile(tex_path, llm_opts, @max_fix_attempts)
        end
    end
  end

  defp fix_latex_via_llm(tex_content, error_log, llm_opts) do
    system = """
    You are a LaTeX expert. Fix the following LaTeX document so it compiles \
    without errors. The pdflatex compiler reported these errors:

    #{error_log}

    Return ONLY the complete fixed LaTeX document, nothing else. \
    Do not add explanations. Ensure all special characters like & # _ % \
    are properly escaped when they appear in text (not in LaTeX commands).
    """

    user = """
    Fix this LaTeX document:

    #{String.slice(tex_content, 0, 12000)}
    """

    model = Keyword.get(llm_opts, :model, "gpt-4o")
    max_tokens = Keyword.get(llm_opts, :max_tokens, 8192)
    temperature = Keyword.get(llm_opts, :temperature, 0.2)

    AgentOS.LLMClient.chat(
      [%{role: "system", content: system}, %{role: "user", content: user}],
      model: model, max_tokens: max_tokens, temperature: temperature
    )
  end
end
