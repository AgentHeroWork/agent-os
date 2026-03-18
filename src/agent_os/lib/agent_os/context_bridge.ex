defmodule AgentOS.ContextBridge do
  @moduledoc """
  Translates between ContextFS structured memory and plain files for microVMs.

  Before VM boot: queries ContextFS via CLI, renders results as .md files in a
  context directory that gets mounted read-only into the microVM at /context/.

  After VM completes: scans /shared/output/ for files the agent wrote, ingests
  each into ContextFS with agent_id, task_id, and lineage tags.

  Agents never call ContextFS directly. They read .md files and write output files.
  The orchestrator (this module) handles all ContextFS interaction on the host.
  """

  require Logger

  @tmp_base "/tmp/agent-os/pipeline"

  @doc """
  Prepares context directory for a microVM agent.

  Queries ContextFS for relevant prior work, decisions, and facts based on
  the topic, then renders them as plain .md files. Returns the path to the
  context directory (to be mounted as /context/ read-only).
  """
  @spec prepare_context(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def prepare_context(task, agent_spec) do
    task_id = Map.get(task, :id, "task_#{:erlang.unique_integer([:positive])}")
    context_dir = Path.join(@tmp_base, "context-#{task_id}")
    File.mkdir_p!(context_dir)

    topic = Map.get(task, :topic, "general research")
    agent_name = Map.get(agent_spec, :name, "agent")
    stage = Map.get(agent_spec, :stage, :default)

    # Write the task brief
    brief = build_brief(task, agent_spec)
    File.write!(Path.join(context_dir, "brief.md"), brief)

    # Query ContextFS for relevant context (runs on host via CLI)
    prior_work = contextfs_search(topic, type: "agent_run", limit: 5)
    render_search_results(context_dir, "prior-work.md", "Prior Work", prior_work)

    decisions = contextfs_search(topic, type: "decision", limit: 5)
    render_search_results(context_dir, "team-decisions.md", "Team Decisions", decisions)

    facts = contextfs_search(topic, type: "fact", limit: 10)
    render_search_results(context_dir, "known-facts.md", "Known Facts", facts)

    # Copy any additional files from previous pipeline stages
    prev_output = Map.get(task, :previous_output_dir)

    if prev_output && File.dir?(prev_output) do
      copy_previous_outputs(prev_output, context_dir)
    end

    Logger.info("ContextBridge: prepared context for #{agent_name}/#{stage} at #{context_dir}")
    {:ok, context_dir}
  end

  @doc """
  Creates the output directory for a microVM agent.
  Returns the path (to be mounted as /shared/output/ read-write).
  """
  @spec prepare_output_dir(String.t()) :: String.t()
  def prepare_output_dir(task_id) do
    output_dir = Path.join(@tmp_base, "output-#{task_id}")
    File.mkdir_p!(output_dir)
    output_dir
  end

  @doc """
  Ingests agent output files from /shared/output/ into ContextFS.

  Scans the output directory, reads each file, and saves to ContextFS
  with appropriate type, tags, and summary. Called after VM completes.
  """
  @spec ingest_output(map(), String.t(), String.t()) :: :ok
  def ingest_output(task, agent_id, output_dir) do
    task_id = Map.get(task, :id, "unknown")

    case File.ls(output_dir) do
      {:ok, files} ->
        Enum.each(files, fn filename ->
          path = Path.join(output_dir, filename)

          case File.read(path) do
            {:ok, content} when byte_size(content) > 0 ->
              type = infer_type(filename)
              tags = ["agent:#{agent_id}", "task:#{task_id}", "pipeline"]
              summary = extract_summary(content, filename)

              contextfs_save(content, type: type, tags: tags, summary: summary)
              Logger.info("ContextBridge: ingested #{filename} as #{type}")

            _ ->
              Logger.warning("ContextBridge: skipping empty file #{filename}")
          end
        end)

        :ok

      {:error, reason} ->
        Logger.warning("ContextBridge: could not read output dir #{output_dir}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Cleans up temporary context and output directories for a task.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(task_id) do
    File.rm_rf(Path.join(@tmp_base, "context-#{task_id}"))
    File.rm_rf(Path.join(@tmp_base, "output-#{task_id}"))
    :ok
  end

  # -- ContextFS CLI Interface --

  defp contextfs_search(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    type = Keyword.get(opts, :type)

    args = ["search", query, "--json", "--limit", to_string(limit)]
    args = if type, do: args ++ ["--type", to_string(type)], else: args

    case System.cmd("contextfs", args, stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, results} when is_list(results) -> results
          _ -> []
        end

      {_, _} ->
        Logger.debug("ContextBridge: contextfs search returned no results for '#{query}'")
        []
    end
  rescue
    _ ->
      Logger.warning("ContextBridge: contextfs CLI not available")
      []
  end

  defp contextfs_save(content, opts) do
    type = Keyword.get(opts, :type, "fact")
    tags = Keyword.get(opts, :tags, [])
    summary = Keyword.get(opts, :summary)

    args = ["save", "--type", to_string(type)]
    args = if tags != [], do: args ++ ["--tags", Enum.join(tags, ",")], else: args
    args = if summary, do: args ++ ["--summary", summary], else: args

    case System.cmd("contextfs", args, input: content, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> Logger.warning("ContextBridge: contextfs save failed: #{String.slice(output, 0, 200)}")
    end
  rescue
    _ -> Logger.warning("ContextBridge: contextfs CLI not available for save")
  end

  # -- File Rendering --

  defp build_brief(task, agent_spec) do
    topic = Map.get(task, :topic, "research")
    stage = Map.get(agent_spec, :stage, :default)
    instructions = Map.get(agent_spec, :instructions, "")

    """
    # Task Brief

    **Topic:** #{topic}
    **Stage:** #{stage}
    **Agent:** #{Map.get(agent_spec, :name, "agent")}

    ## Instructions

    #{instructions}

    ## Task Details

    #{Map.get(task, :description, "Complete the assigned task and write output to /shared/output/")}
    """
  end

  defp render_search_results(dir, filename, heading, results) do
    content =
      if results == [] do
        "# #{heading}\n\nNo prior context available.\n"
      else
        entries =
          results
          |> Enum.with_index(1)
          |> Enum.map(fn {result, idx} ->
            summary = get_in_result(result, "summary") || "No summary"
            content = get_in_result(result, "content") || ""
            type = get_in_result(result, "type") || "unknown"
            truncated = String.slice(content, 0, 500)
            "### #{idx}. [#{type}] #{summary}\n\n#{truncated}\n"
          end)
          |> Enum.join("\n---\n\n")

        "# #{heading}\n\n#{entries}"
      end

    File.write!(Path.join(dir, filename), content)
  end

  defp get_in_result(result, key) when is_map(result) do
    Map.get(result, key, Map.get(result, String.to_atom(key)))
  end

  defp get_in_result(_, _), do: nil

  defp copy_previous_outputs(source_dir, target_dir) do
    case File.ls(source_dir) do
      {:ok, files} ->
        Enum.each(files, fn filename ->
          source = Path.join(source_dir, filename)
          target = Path.join(target_dir, filename)

          if File.regular?(source) do
            File.cp!(source, target)
          end
        end)

      _ ->
        :ok
    end
  end

  # -- Type Inference --

  defp infer_type(filename) do
    case Path.extname(filename) do
      ".tex" -> "code"
      ".pdf" -> "code"
      ".py" -> "code"
      ".js" -> "code"
      ".sh" -> "code"
      ".json" -> "config"
      ".yaml" -> "config"
      ".yml" -> "config"
      _ -> "fact"
    end
  end

  defp extract_summary(content, filename) do
    first_line =
      content
      |> String.split("\n", parts: 2)
      |> List.first("")
      |> String.trim()
      |> String.trim_leading("#")
      |> String.trim()

    if String.length(first_line) > 10 do
      String.slice(first_line, 0, 200)
    else
      "Output: #{filename}"
    end
  end
end
