defmodule AgentOS.Secrets do
  @moduledoc "Pluggable secrets management for credential injection into microVMs"

  @callback resolve(credential :: atom()) :: {:ok, String.t()} | {:error, term()}
  @callback available?() :: boolean()

  @doc "Resolve a credential using the configured backend"
  def resolve(credential) do
    backend().resolve(credential)
  end

  @doc "Check if a credential is available"
  def available?(credential) do
    case resolve(credential) do
      {:ok, val} when is_binary(val) and val != "" -> true
      _ -> false
    end
  end

  defp backend do
    Application.get_env(:agent_os, :secrets_backend, AgentOS.Secrets.EnvBackend)
  end
end
