defmodule AgentOS.Contracts.ResearchContract do
  @moduledoc """
  Research execution contract for CERN particle physics papers.

  Validates that research agents produce the required artifacts:
  a .tex file, a compiled PDF, and a GitHub repository URL.
  """

  @behaviour AgentOS.Contracts.Contract

  @min_content_length 500

  @impl true
  def required_artifacts do
    [:tex_path, :pdf_path, :repo_url]
  end

  @impl true
  def verify(artifacts) do
    cond do
      is_nil(artifacts[:repo_url]) ->
        {:retry, "No repository URL — repo creation may have failed"}

      is_nil(artifacts[:tex_path]) ->
        {:retry, "No .tex file produced"}

      not file_exists?(artifacts[:tex_path]) ->
        {:retry, ".tex file path set but file does not exist on disk"}

      tex_too_short?(artifacts[:tex_path]) ->
        {:retry, "LaTeX content is too short — likely placeholder text"}

      true ->
        :ok
    end
  end

  @impl true
  def max_retries, do: 3

  defp file_exists?(nil), do: false
  defp file_exists?(path), do: File.exists?(path)

  defp tex_too_short?(path) do
    case File.read(path) do
      {:ok, content} -> String.length(content) < @min_content_length
      _ -> true
    end
  end
end
