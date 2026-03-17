defmodule AgentScheduler.ResearchPrompts do
  @moduledoc """
  LLM prompt templates for research generation.

  Provides system and user prompts for each agent type and research step.
  Output is structured text (not LaTeX) — the CompletionHandler wraps
  content in LaTeX templates. Exception: math equations use LaTeX math mode.
  """

  @doc """
  Returns {system_message, user_message} for the "plan" step.
  """
  @spec plan_prompt(atom(), String.t()) :: {String.t(), String.t()}
  def plan_prompt(:open_claw, topic) do
    system = """
    You are a senior particle physics researcher at CERN with expertise in \
    experimental and theoretical high-energy physics. You are planning a \
    research paper. Be specific about sections, key arguments, and references \
    to include. Output a structured research plan.
    """

    user = """
    Plan a detailed research paper on the following topic:

    Topic: #{topic}

    Provide your plan as a structured outline with:
    1. Paper title
    2. Abstract summary (2-3 sentences)
    3. Section outline (Introduction, Theoretical Framework, Experimental Evidence, Analysis, Conclusions)
    4. Key arguments and claims for each section
    5. At least 15 specific references to cite (real papers, authors, journals)
    """

    {String.trim(system), String.trim(user)}
  end

  def plan_prompt(:nemo_claw, topic) do
    system = """
    You are a privacy-preserving computation researcher specializing in \
    applying differential privacy, federated learning, and homomorphic \
    encryption to high-energy physics data analysis. You are planning a \
    research paper. Focus on privacy guarantees and their trade-offs with \
    analytical utility.
    """

    user = """
    Plan a detailed research paper on the following topic:

    Topic: #{topic}

    Provide your plan as a structured outline with:
    1. Paper title
    2. Abstract summary (2-3 sentences)
    3. Section outline (Introduction, Privacy Framework, Methods, Application to CERN Data, Results, Conclusions)
    4. Key arguments about privacy-utility trade-offs
    5. At least 15 specific references to cite (real papers on differential privacy, federated learning, HEP)
    """

    {String.trim(system), String.trim(user)}
  end

  def plan_prompt(_agent_type, topic) do
    plan_prompt(:open_claw, topic)
  end

  @doc """
  Returns {system_message, user_message} for the "research" step.
  This is the main content generation step.
  """
  @spec research_prompt(atom(), String.t(), String.t()) :: {String.t(), String.t()}
  def research_prompt(:open_claw, topic, plan) do
    system = """
    You are a senior particle physics researcher at CERN. Write a detailed, \
    substantive research paper. Include real physics concepts, equations in \
    LaTeX math mode ($...$ for inline, $$...$$ for display), experimental \
    data references, and analytical rigor.

    IMPORTANT: Output ONLY the text content for each section. Do NOT include \
    LaTeX document preamble, \\documentclass, \\begin{document}, or section \
    commands. The system will wrap your content in a LaTeX template.

    Format your response EXACTLY as follows (use these exact markers):

    TITLE: <paper title>
    ABSTRACT: <abstract text>
    INTRODUCTION: <introduction content>
    THEORETICAL_FRAMEWORK: <theoretical framework content>
    EXPERIMENTAL_EVIDENCE: <experimental evidence content>
    ANALYSIS: <analysis and discussion content>
    CONCLUSIONS: <conclusions content>
    REFERENCES: <numbered reference list, one per line>
    """

    user = """
    Write a complete research paper based on this plan:

    Topic: #{topic}

    Plan:
    #{plan}

    Requirements:
    - Each section should be at least 3 paragraphs
    - Include at least 5 equations in LaTeX math mode
    - Reference at least 15 real papers with authors, titles, journals, and years
    - Discuss experimental results from CERN (LHC, ATLAS, CMS, etc.)
    - Be scientifically rigorous and substantive
    """

    {String.trim(system), String.trim(user)}
  end

  def research_prompt(:nemo_claw, topic, plan) do
    system = """
    You are a privacy-preserving computation researcher. Write a detailed \
    research paper on applying privacy techniques to CERN/HEP data analysis. \
    Cover differential privacy, federated learning, homomorphic encryption, \
    and secure multi-party computation. Include mathematical formulations \
    in LaTeX math mode ($...$ for inline, $$...$$ for display).

    IMPORTANT: Output ONLY the text content for each section. Do NOT include \
    LaTeX document preamble, \\documentclass, \\begin{document}, or section \
    commands. The system will wrap your content in a LaTeX template.

    Format your response EXACTLY as follows (use these exact markers):

    TITLE: <paper title>
    ABSTRACT: <abstract text>
    INTRODUCTION: <introduction content>
    PRIVACY_FRAMEWORK: <privacy framework content>
    METHODS: <methods and techniques content>
    APPLICATION: <application to CERN data content>
    RESULTS: <results and evaluation content>
    CONCLUSIONS: <conclusions content>
    REFERENCES: <numbered reference list, one per line>
    """

    user = """
    Write a complete research paper based on this plan:

    Topic: #{topic}

    Plan:
    #{plan}

    Requirements:
    - Each section should be at least 3 paragraphs
    - Include privacy budget equations ($\\epsilon$-differential privacy)
    - Reference at least 15 real papers on privacy-preserving computation and HEP
    - Discuss specific CERN use cases (detector calibration, cross-experiment analysis)
    - Address the privacy-utility trade-off quantitatively
    """

    {String.trim(system), String.trim(user)}
  end

  def research_prompt(agent_type, topic, plan) do
    research_prompt(:open_claw, agent_type |> to_string() |> then(&"#{topic} (#{&1})"), plan)
  end

  @doc """
  Returns {system_message, user_message} for the "review" step.
  """
  @spec review_prompt(String.t(), String.t()) :: {String.t(), String.t()}
  def review_prompt(topic, content) do
    system = """
    You are a peer reviewer for a physics journal. Review the following \
    research paper for scientific accuracy, completeness, and quality. \
    Provide specific suggestions for improvement. If the paper is acceptable, \
    state "ACCEPT" at the beginning of your review.
    """

    user = """
    Review this research paper:

    Topic: #{topic}

    Content:
    #{String.slice(content, 0, 8000)}

    Evaluate:
    1. Scientific accuracy
    2. Completeness of arguments
    3. Quality of references
    4. Mathematical rigor
    5. Overall recommendation (ACCEPT or REVISE)
    """

    {String.trim(system), String.trim(user)}
  end

  @doc """
  Parses structured LLM output into a result map with :topic, :abstract, :content, :references.
  """
  @spec parse_research_output(String.t()) :: map()
  def parse_research_output(text) do
    sections = parse_sections(text)

    title = sections["TITLE"] || "Untitled Research"
    abstract = sections["ABSTRACT"] || ""

    # Combine all body sections into content
    body_keys =
      sections
      |> Map.keys()
      |> Enum.reject(&(&1 in ["TITLE", "ABSTRACT", "REFERENCES"]))
      |> Enum.sort()

    content =
      body_keys
      |> Enum.map(fn key ->
        section_title = key |> String.replace("_", " ") |> String.capitalize()
        "\\section{#{section_title}}\n\n#{sections[key]}"
      end)
      |> Enum.join("\n\n")

    references = parse_references(sections["REFERENCES"] || "")

    %{
      topic: title,
      abstract: abstract,
      content: content,
      references: references
    }
  end

  defp parse_sections(text) do
    # Match section markers like "TITLE: content" or "INTRODUCTION: content"
    pattern = ~r/^([A-Z_]+):\s*/m

    parts = Regex.split(pattern, text, include_captures: true, trim: true)

    parts
    |> chunk_pairs()
    |> Map.new()
  end

  defp chunk_pairs(list), do: chunk_pairs(list, %{})
  defp chunk_pairs([], acc), do: acc

  defp chunk_pairs([key, value | rest], acc) do
    key = key |> String.trim() |> String.trim_trailing(":")
    value = String.trim(value)
    chunk_pairs(rest, Map.put(acc, key, value))
  end

  defp chunk_pairs([_orphan], acc), do: acc

  defp parse_references(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn ref ->
      # Strip leading numbering like "[1]" or "1." or "1)"
      Regex.replace(~r/^\[?\d+[\].)]\s*/, ref, "")
    end)
  end
end
