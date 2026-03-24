defmodule AgentOS.Notifications.Dispatcher do
  @moduledoc """
  Dispatches notification events to all configured plugins.

  Auto-discovers plugins based on environment variables. If no tokens are set,
  no notifications are sent (noop).
  """

  require Logger

  @doc "Dispatch an event to all configured notification plugins"
  def dispatch(event, data) do
    plugins()
    |> Enum.each(fn {module, config} ->
      try do
        module.send_notification(event, data, config)
      rescue
        e -> Logger.warning("Notification dispatch failed for #{module}: #{Exception.message(e)}")
      end
    end)
  end

  defp plugins do
    []
    |> maybe_add_slack()
    |> maybe_add_telegram()
  end

  defp maybe_add_slack(list) do
    case System.get_env("SLACK_BOT_TOKEN") do
      nil ->
        list

      _ ->
        channel = System.get_env("SLACK_CHANNEL") || "#agentos"
        [{AgentOS.Notifications.Slack, %{channel: channel}} | list]
    end
  end

  defp maybe_add_telegram(list) do
    case System.get_env("TELEGRAM_BOT_TOKEN") do
      nil ->
        list

      _ ->
        chat_id = System.get_env("TELEGRAM_CHAT_ID")

        if chat_id,
          do: [{AgentOS.Notifications.Telegram, %{chat_id: chat_id}} | list],
          else: list
    end
  end
end
