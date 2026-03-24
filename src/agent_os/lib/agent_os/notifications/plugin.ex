defmodule AgentOS.Notifications.Plugin do
  @moduledoc """
  Behaviour for notification plugins.

  Implement this behaviour to add a new notification channel (Slack, Telegram, etc).
  """

  @callback send_notification(event :: atom(), data :: map(), config :: map()) :: :ok | {:error, term()}
  @callback supports_interactive?() :: boolean()
  @callback name() :: String.t()
end
