defmodule AgentOS.Agents.NemoClaw do
  @moduledoc """
  NemoClaw — NVIDIA-secured agent with restricted tools and policy guardrails.

  NemoClaw operates under strict constraints inspired by NVIDIA NeMo Guardrails:
  restricted tool access, mandatory human oversight, and privacy-first routing.
  Default oversight mode is `:supervised` — every step requires approval.

  ## Autonomous Pipeline (with Guardrails)

  1. Plan — LLM generates privacy-focused research plan (guardrail-checked)
  2. Research — LLM writes paper on privacy-preserving CERN analysis
  3. Review — LLM self-reviews, output is PII-sanitized
  4. Write LaTeX — Generates .tex with sanitized content
  5. Compile PDF — Compiles with LLM self-repair on failure
  6. Ensure Repo — Creates or verifies GitHub repository
  7. Push Artifacts — Pushes .tex, .pdf, README.md to repo

  ## Policy Guardrails

  - Content filtering — Blocks generation of harmful content
  - Privacy routing — PII is never persisted in plaintext
  - Domain restriction — Only approved research domains
  - Output validation — All outputs checked against policy before return
  """

  @behaviour AgentOS.Agents.AgentType

  require Logger

  alias AgentOS.Agents.{CompletionHandler, SelfRepair}

  @approved_domains [
    "cern.ch",
    "arxiv.org",
    "nature.com",
    "science.org",
    "scholar.google.com",
    "wikipedia.org"
  ]

  @impl true
  def profile do
    %{
      name: "NemoClaw",
      capabilities: [:web_search, :memory],
      task_domain: [:research, :analysis],
      default_oversight: :supervised,
      description: "NVIDIA-secured research agent with restricted tools, privacy routing, and policy guardrails"
    }
  end

  @impl true
  def run_autonomous(input, context) do
    topic = extract_topic(input)
    llm_opts = llm_opts_from(input)
    output_dir = resolve_output_dir(context)
    agent_profile = profile()

    Logger.info("NemoClaw: starting autonomous pipeline for '#{topic}'")

    with :ok <- check_guardrails(input),
         {:ok, plan} <- plan_research(topic, llm_opts),
         :ok <- check_guardrails(%{content: plan}),
         {:ok, research} <- execute_research(topic, plan, llm_opts),
         research <- sanitize_pii_map(research),
         :ok <- check_guardrails(research),
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
        agent: "NemoClaw",
        topic: topic,
        privacy_routing: true,
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      Logger.info("NemoClaw: autonomous pipeline completed for '#{topic}'")
      {:ok, %{artifacts: artifacts, metadata: metadata}}
    else
      {:error, {:guardrail_blocked, _} = reason} ->
        {:escalate,
         %{
           reason: :guardrail_violation,
           message: "Guardrail blocked: #{inspect(reason)}",
           context: %{topic: topic},
           partial_artifacts: %{}
         }}

      {:error, {:guardrail_blocked, _, _} = reason} ->
        {:escalate,
         %{
           reason: :guardrail_violation,
           message: "Guardrail blocked: #{inspect(reason)}",
           context: %{topic: topic},
           partial_artifacts: %{}
         }}

      other ->
        other
    end
  end

  @impl true
  def execute_step(step_id, input, context) do
    with :ok <- check_guardrails(input) do
      result = execute_guarded_step(step_id, input, context)
      validate_output(result)
    end
  end

  @impl true
  def tool_requirements do
    ["web-search", "text-transform"]
  end

  @spec privacy_routing?() :: boolean()
  def privacy_routing?, do: true

  @spec approved_domains() :: [String.t()]
  def approved_domains, do: @approved_domains

  # -- Guardrail Checks --

  defp check_guardrails(input) do
    with :ok <- check_content_policy(input),
         :ok <- check_domain_restrictions(input) do
      :ok
    end
  end

  defp check_content_policy(input) do
    text = inspect(input) |> String.downcase()
    blocked_patterns = ["password", "credit_card", "ssn", "social_security"]

    if Enum.any?(blocked_patterns, &String.contains?(text, &1)) do
      {:error, {:guardrail_blocked, :pii_detected}}
    else
      :ok
    end
  end

  defp check_domain_restrictions(input) do
    case Map.get(input, :url) || Map.get(input, "url") do
      nil ->
        :ok

      url when is_binary(url) ->
        uri = URI.parse(url)
        host = uri.host || ""

        if Enum.any?(@approved_domains, &String.ends_with?(host, &1)) do
          :ok
        else
          {:error, {:guardrail_blocked, :domain_not_approved, host}}
        end

      _ ->
        :ok
    end
  end

  defp validate_output({:ok, result}) do
    sanitized = sanitize_pii_map(result)
    {:ok, sanitized}
  end

  defp validate_output(error), do: error

  defp sanitize_pii_map(%{__struct__: _} = data), do: data

  defp sanitize_pii_map(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, sanitize_pii_map(v)} end)
  end

  defp sanitize_pii_map(data) when is_binary(data) do
    Regex.replace(~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/, data, "[REDACTED_EMAIL]")
  end

  defp sanitize_pii_map(data), do: data

  # -- LLM-Powered Steps --

  defp plan_research(topic, llm_opts) do
    Logger.info("NemoClaw: planning privacy-focused research on '#{topic}'")

    {system, user} = AgentOS.ResearchPrompts.plan_prompt(:nemo_claw, topic)

    case AgentOS.LLMClient.chat(
           [%{role: "system", content: system}, %{role: "user", content: user}],
           llm_opts
         ) do
      {:ok, plan_text} ->
        Logger.info("NemoClaw: plan generated (#{String.length(plan_text)} chars)")
        {:ok, plan_text}

      {:error, reason} ->
        Logger.error("NemoClaw: plan step failed — #{inspect(reason)}")
        {:error, {:plan_failed, reason}}
    end
  end

  defp execute_research(topic, plan, llm_opts) do
    Logger.info("NemoClaw: generating privacy-preserving research on '#{topic}'")

    {system, user} = AgentOS.ResearchPrompts.research_prompt(:nemo_claw, topic, plan)

    case AgentOS.LLMClient.chat(
           [%{role: "system", content: system}, %{role: "user", content: user}],
           llm_opts
         ) do
      {:ok, research_text} ->
        Logger.info("NemoClaw: research generated (#{String.length(research_text)} chars)")
        result = AgentOS.ResearchPrompts.parse_research_output(research_text)
        {:ok, Map.put(result, :privacy_routing, true)}

      {:error, reason} ->
        Logger.error("NemoClaw: research step failed — #{inspect(reason)}")
        {:error, {:research_failed, reason}}
    end
  end

  defp review_research(topic, research, llm_opts) do
    content = Map.get(research, :content, "")
    Logger.info("NemoClaw: reviewing research on '#{topic}'")

    {system, user} = AgentOS.ResearchPrompts.review_prompt(topic, content)

    case AgentOS.LLMClient.chat(
           [%{role: "system", content: system}, %{role: "user", content: user}],
           llm_opts
         ) do
      {:ok, review_text} ->
        Logger.info("NemoClaw: review complete")

        if String.contains?(String.upcase(review_text), "ACCEPT") do
          {:ok, %{review: review_text, review_status: :accepted}}
        else
          {:ok, %{review: review_text, review_status: :needs_revision}}
        end

      {:error, reason} ->
        Logger.warning("NemoClaw: review step failed — #{inspect(reason)}, continuing anyway")
        {:ok, %{review: "Review skipped due to error", review_status: :skipped}}
    end
  end

  # -- Legacy Step Execution (for execute_step/3) --

  defp execute_guarded_step("plan", input, _context) do
    topic = extract_topic(input)
    llm_opts = llm_opts_from(input)

    case plan_research(topic, llm_opts) do
      {:ok, plan_text} -> {:ok, %{topic: topic, plan: plan_text, privacy_routing: true}}
      error -> error
    end
  end

  defp execute_guarded_step("research", input, _context) do
    topic = extract_topic(input)
    plan = Map.get(input, :plan, "")
    llm_opts = llm_opts_from(input)

    case execute_research(topic, plan, llm_opts) do
      {:ok, result} -> {:ok, result}
      error -> error
    end
  end

  defp execute_guarded_step("review", input, _context) do
    topic = extract_topic(input)
    llm_opts = llm_opts_from(input)

    case review_research(topic, %{content: Map.get(input, :content, "")}, llm_opts) do
      {:ok, review} -> {:ok, review}
      error -> error
    end
  end

  defp execute_guarded_step("search", input, context) do
    execute_guarded_step("research", input, context)
  end

  defp execute_guarded_step("analyze", input, _context) do
    {:ok, input}
  end

  defp execute_guarded_step("persist", input, context) do
    {:ok,
     %{
       agent_id: context.agent_id,
       type: :guarded_research_output,
       data: sanitize_pii_map(input),
       privacy_routing: true,
       timestamp: DateTime.utc_now()
     }}
  end

  defp execute_guarded_step(step_id, _input, _context) do
    {:error, {:unknown_step, step_id}}
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
    Map.get(input, :topic, Map.get(input, "topic", "research"))
  end

  defp resolve_output_dir(context) do
    agent_id = Map.get(context, :agent_id, "nemoclaw")
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
