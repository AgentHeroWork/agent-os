defmodule AgentOS.Notifications.Interactive do
  @moduledoc """
  Interactive agent-to-human communication via notification channels.

  When an agent writes `_question.json` to `/shared/output/`, the pipeline
  can read it and route the question to configured notification channels
  that support interactive responses.

  ## Question Format

      %{
        "question" => "Should I use React or Vue for the dashboard?",
        "context" => "The client mentioned preference for React in the brief",
        "options" => ["React", "Vue", "Let me decide"],
        "timeout_minutes" => 30
      }

  ## Flow

  1. Agent writes _question.json during execution
  2. Pipeline reads it after stage completes
  3. Dispatcher sends to interactive-capable plugins (Slack with threads)
  4. Plugin waits for human response (with timeout)
  5. Response is written to next stage's /context/answer.md

  TODO: Wire into Pipeline stage transitions
  """

  @doc """
  Checks for a `_question.json` file in the given output directory.

  Returns `{:ok, question_map}` if a question file exists and is valid JSON,
  or `{:ok, nil}` if no question file is present.
  """
  @spec check_for_question(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def check_for_question(output_dir) do
    path = Path.join(output_dir, "_question.json")

    case File.read(path) do
      {:ok, json} -> Jason.decode(json)
      _ -> {:ok, nil}
    end
  end
end
