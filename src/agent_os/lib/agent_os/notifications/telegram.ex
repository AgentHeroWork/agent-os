defmodule AgentOS.Notifications.Telegram do
  @moduledoc """
  Telegram notification plugin.

  Sends pipeline events to a Telegram chat via the Bot API.
  Requires `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` environment variables.
  """

  @behaviour AgentOS.Notifications.Plugin

  require Logger

  @impl true
  def name, do: "Telegram"

  @impl true
  def supports_interactive?, do: false

  @impl true
  def send_notification(event, data, config) do
    token = System.get_env("TELEGRAM_BOT_TOKEN")
    chat_id = config[:chat_id]
    message = format_message(event, data)
    send_message(token, chat_id, message)
  end

  defp format_message(:pipeline_complete, data) do
    "Pipeline Complete\n" <>
      "Contract: #{data[:contract_name]}\n" <>
      "Topic: #{data[:topic]}\n" <>
      "Duration: #{data[:duration_ms]}ms\n" <>
      "Artifacts: #{inspect(Map.keys(data[:artifacts] || %{}))}"
  end

  defp format_message(:pipeline_failed, data) do
    "Pipeline Failed\n" <>
      "Contract: #{data[:contract_name]}\n" <>
      "Stage: #{data[:stage]}\n" <>
      "Error: #{inspect(data[:error])}"
  end

  defp format_message(:escalation, data) do
    "Agent Escalation\n" <>
      "Reason: #{data[:reason]}\n" <>
      "Message: #{data[:message]}"
  end

  defp format_message(event, data) do
    "#{event}\n#{inspect(data)}"
  end

  defp send_message(nil, _chat_id, _text), do: {:error, :no_token}
  defp send_message(_token, nil, _text), do: {:error, :no_chat_id}

  defp send_message(token, chat_id, text) do
    body = Jason.encode!(%{chat_id: chat_id, text: text})
    url = ~c"https://api.telegram.org/bot#{token}/sendMessage"

    headers = [
      {~c"content-type", ~c"application/json"}
    ]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      error ->
        Logger.warning("Telegram notification failed: #{inspect(error)}")
        {:error, error}
    end
  end
end
