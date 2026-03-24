defmodule AgentOS.Notifications.Slack do
  @moduledoc """
  Slack notification plugin.

  Sends pipeline events to a Slack channel via the Slack Web API.
  Requires `SLACK_BOT_TOKEN` environment variable.
  """

  @behaviour AgentOS.Notifications.Plugin

  require Logger

  @impl true
  def name, do: "Slack"

  @impl true
  def supports_interactive?, do: false

  @impl true
  def send_notification(event, data, config) do
    token = System.get_env("SLACK_BOT_TOKEN")
    channel = config[:channel] || "#agentos"
    message = format_message(event, data)
    post_message(token, channel, message)
  end

  defp format_message(:pipeline_complete, data) do
    "*Pipeline Complete* :white_check_mark:\n" <>
      "*Contract:* #{data[:contract_name]}\n" <>
      "*Topic:* #{data[:topic]}\n" <>
      "*Duration:* #{data[:duration_ms]}ms\n" <>
      "*Artifacts:* #{inspect(Map.keys(data[:artifacts] || %{}))}"
  end

  defp format_message(:pipeline_failed, data) do
    "*Pipeline Failed* :x:\n" <>
      "*Contract:* #{data[:contract_name]}\n" <>
      "*Stage:* #{data[:stage]}\n" <>
      "*Error:* #{inspect(data[:error])}"
  end

  defp format_message(:escalation, data) do
    "*Agent Escalation* :warning:\n" <>
      "*Reason:* #{data[:reason]}\n" <>
      "*Message:* #{data[:message]}"
  end

  defp format_message(event, data) do
    "*#{event}*\n#{inspect(data)}"
  end

  defp post_message(nil, _channel, _text), do: {:error, :no_token}

  defp post_message(token, channel, text) do
    body = Jason.encode!(%{channel: channel, text: text})
    url = ~c"https://slack.com/api/chat.postMessage"

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"authorization", ~c"Bearer #{token}"}
    ]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      error ->
        Logger.warning("Slack notification failed: #{inspect(error)}")
        {:error, error}
    end
  end
end
