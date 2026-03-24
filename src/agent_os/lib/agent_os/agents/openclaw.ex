defmodule AgentOS.Agents.OpenClaw do
  @moduledoc """
  OpenClaw — Full-capability autonomous research agent.

  OpenClaw is designed for open-ended research tasks with broad tool access:
  web search, browser automation, filesystem operations, and shell execution.
  Default oversight mode is `:autonomous_escalation` — the agent runs freely
  and only escalates when confidence drops below threshold.

  ## Autonomous Pipeline

  1. Plan — LLM generates a structured research plan
  2. Research — LLM writes full paper content (abstract, sections, references)
  3. Review — LLM self-reviews for quality and completeness
  4. Write LaTeX — Generates .tex file from research content
  5. Compile PDF — Compiles with LLM self-repair on failure
  6. Ensure Repo — Creates or verifies GitHub repository
  7. Push Artifacts — Pushes .tex, .pdf, README.md to repo
  """

  @behaviour AgentOS.Agents.AgentType

  require Logger

  alias AgentOS.Agents.{CompletionHandler, SelfRepair}

  @impl true
  def profile do
    %{
      name: "OpenClaw",
      capabilities: [:web_search, :browser, :filesystem, :shell, :memory],
      task_domain: [:research, :analysis, :data_collection, :report_generation],
      default_oversight: :autonomous_escalation,
      description: "Full-capability autonomous research agent with web, filesystem, and shell access"
    }
  end

  @impl true
  def run_autonomous(input, context) do
    topic = extract_topic(input)
    llm_opts = llm_opts_from(input)
    output_dir = resolve_output_dir(context)
    agent_profile = profile()

    Logger.info("OpenClaw: starting autonomous pipeline for '#{topic}'")

    with {:ok, plan} <- plan_research(topic, llm_opts),
         {:ok, research} <- execute_research(topic, plan, llm_opts),
         {:ok, _review} <- review_research(topic, research, llm_opts),
         {:ok, tex_path} <- CompletionHandler.write_latex(research, agent_profile, output_dir),
         {:ok, pdf_path} <- compile_pdf_or_escalate(tex_path, llm_opts),
         {:ok, repo_url} <- ensure_repo_or_escalate(agent_profile, topic),
         readme <- CompletionHandler.generate_readme(agent_profile, research, repo_url),
         :ok <- push_or_escalate(repo_url, [tex_path, pdf_path], readme) do
      artifacts = %{
        tex_path: tex_path,
        pdf_path: pdf_path,
        repo_url: repo_url,
        readme_content: readme
      }

      metadata = %{
        agent: "OpenClaw",
        topic: topic,
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      Logger.info("OpenClaw: autonomous pipeline completed for '#{topic}'")
      {:ok, %{artifacts: artifacts, metadata: metadata}}
    end
  end

  @impl true
  def execute_step(step_id, input, _context) do
    case step_id do
      "plan" ->
        topic = extract_topic(input)
        llm_opts = llm_opts_from(input)

        case plan_research(topic, llm_opts) do
          {:ok, plan_text} -> {:ok, %{topic: topic, plan: plan_text}}
          error -> error
        end

      "research" ->
        topic = extract_topic(input)
        plan = Map.get(input, :plan, "")
        llm_opts = llm_opts_from(input)

        case execute_research(topic, plan, llm_opts) do
          {:ok, result} -> {:ok, result}
          error -> error
        end

      "review" ->
        topic = extract_topic(input)
        content = Map.get(input, :content, "")
        llm_opts = llm_opts_from(input)

        case review_research(topic, %{content: content}, llm_opts) do
          {:ok, review} -> {:ok, review}
          error -> error
        end

      "search" ->
        topic = extract_topic(input)
        plan = Map.get(input, :plan, "")
        llm_opts = llm_opts_from(input)

        case execute_research(topic, plan, llm_opts) do
          {:ok, result} -> {:ok, result}
          error -> error
        end

      "analyze" -> {:ok, input}
      "synthesize" -> {:ok, input}
      "persist" -> {:ok, input}
      _ -> {:error, {:unknown_step, step_id}}
    end
  end

  @impl true
  def tool_requirements do
    ["web-search", "web-scrape", "shell-exec", "file-ops", "code-exec"]
  end

  # -- LLM-Powered Steps --

  defp plan_research(topic, llm_opts) do
    Logger.info("OpenClaw: planning research on '#{topic}'")

    {system, user} = AgentOS.ResearchPrompts.plan_prompt(:open_claw, topic)

    case AgentOS.LLMClient.chat(
           [%{role: "system", content: system}, %{role: "user", content: user}],
           llm_opts
         ) do
      {:ok, plan_text} ->
        Logger.info("OpenClaw: plan generated (#{String.length(plan_text)} chars)")
        {:ok, plan_text}

      {:error, reason} ->
        Logger.error("OpenClaw: plan step failed — #{inspect(reason)}")
        {:error, {:plan_failed, reason}}
    end
  end

  defp execute_research(topic, plan, llm_opts) do
    Logger.info("OpenClaw: generating research paper on '#{topic}'")

    {system, user} = AgentOS.ResearchPrompts.research_prompt(:open_claw, topic, plan)

    case AgentOS.LLMClient.chat(
           [%{role: "system", content: system}, %{role: "user", content: user}],
           llm_opts
         ) do
      {:ok, research_text} ->
        Logger.info("OpenClaw: research generated (#{String.length(research_text)} chars)")
        result = AgentOS.ResearchPrompts.parse_research_output(research_text)
        {:ok, result}

      {:error, reason} ->
        Logger.error("OpenClaw: research step failed — #{inspect(reason)}")
        {:error, {:research_failed, reason}}
    end
  end

  defp review_research(topic, research, llm_opts) do
    content = Map.get(research, :content, "")
    Logger.info("OpenClaw: reviewing research on '#{topic}'")

    {system, user} = AgentOS.ResearchPrompts.review_prompt(topic, content)

    case AgentOS.LLMClient.chat(
           [%{role: "system", content: system}, %{role: "user", content: user}],
           llm_opts
         ) do
      {:ok, review_text} ->
        Logger.info("OpenClaw: review complete")

        if String.contains?(String.upcase(review_text), "ACCEPT") do
          {:ok, %{review: review_text, review_status: :accepted}}
        else
          {:ok, %{review: review_text, review_status: :needs_revision}}
        end

      {:error, reason} ->
        Logger.warning("OpenClaw: review step failed — #{inspect(reason)}, continuing anyway")
        {:ok, %{review: "Review skipped due to error", review_status: :skipped}}
    end
  end

  # -- Escalation Wrappers --

  defp compile_pdf_or_escalate(tex_path, llm_opts) do
    case SelfRepair.compile_pdf_with_fix(tex_path, llm_opts) do
      {:ok, pdf_path} ->
        {:ok, pdf_path}

      {:error, :compilation_exhausted} ->
        {:escalate,
         %{
           reason: :compilation_stuck,
           message: "PDF compilation failed after all fix attempts",
           context: %{tex_path: tex_path},
           partial_artifacts: %{tex_path: tex_path}
         }}
    end
  end

  defp ensure_repo_or_escalate(agent_profile, topic) do
    case CompletionHandler.ensure_repo(agent_profile, topic) do
      {:ok, repo_url} ->
        {:ok, repo_url}

      {:error, reason} ->
        {:escalate,
         %{
           reason: :infrastructure_failure,
           message: "GitHub repo creation failed: #{inspect(reason)}",
           context: %{topic: topic},
           partial_artifacts: %{}
         }}
    end
  end

  defp push_or_escalate(repo_url, file_paths, readme_content) do
    valid_paths = Enum.reject(file_paths, &is_nil/1)

    case CompletionHandler.push_artifacts(repo_url, valid_paths, readme_content) do
      :ok ->
        :ok

      {:error, reason} ->
        {:escalate,
         %{
           reason: :infrastructure_failure,
           message: "Artifact push failed: #{inspect(reason)}",
           context: %{repo_url: repo_url},
           partial_artifacts: %{repo_url: repo_url}
         }}
    end
  end

  # -- Helpers --

  defp extract_topic(input) do
    Map.get(input, :topic, Map.get(input, "topic", "general research"))
  end

  defp resolve_output_dir(context) do
    agent_id = Map.get(context, :agent_id, "openclaw")
    base = Map.get(context, :output_dir, CompletionHandler.default_output_dir())
    dir = Path.join(base, agent_id)
    File.mkdir_p!(dir)
    dir
  end

  defp llm_opts_from(input) do
    llm_config = Map.get(input, :llm_config, %{})

    []
    |> maybe_add(:provider, llm_config[:provider])
    |> maybe_add(:model, llm_config[:model])
    |> maybe_add(:api_key, llm_config[:api_key])
    |> maybe_add(:temperature, llm_config[:temperature])
    |> maybe_add(:max_tokens, llm_config[:max_tokens])
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, val), do: Keyword.put(opts, key, val)
end
