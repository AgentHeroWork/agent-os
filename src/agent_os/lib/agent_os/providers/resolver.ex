defmodule AgentOS.Providers.Resolver do
  @moduledoc """
  Resolves which provider to use based on configuration.

  Resolution order:
  1. Explicit provider atom passed to `resolve/1`: `resolve(:fly)`
  2. `AGENT_OS_TARGET` environment variable: `"fly"`, `"local"`, `"e2b"`
  3. Default: `:local` (BEAM-native execution)

  ## Examples

      iex> AgentOS.Providers.Resolver.resolve(:fly)
      AgentOS.Providers.Fly

      iex> AgentOS.Providers.Resolver.resolve(nil)
      AgentOS.Providers.Local

      iex> AgentOS.Providers.Resolver.resolve()
      AgentOS.Providers.Local
  """

  @providers %{
    local: AgentOS.Providers.Local,
    fly: AgentOS.Providers.Fly
  }

  @doc """
  Resolves a provider module from an explicit atom or falls back to env/default.

  ## Parameters

    * `provider` — An atom identifying the provider (`:local`, `:fly`), or `nil`
      to use environment-based resolution.

  ## Returns

  The provider module implementing `AgentOS.Providers.Provider`.
  """
  @spec resolve(atom() | nil) :: module()
  def resolve(nil), do: resolve_from_env()

  def resolve(provider) when is_atom(provider) do
    Map.get(@providers, provider, AgentOS.Providers.Local)
  end

  @doc """
  Resolves a provider using the default resolution chain (env var then default).

  Equivalent to calling `resolve(nil)`.
  """
  @spec resolve() :: module()
  def resolve, do: resolve(nil)

  @doc """
  Resolves the provider from the `AGENT_OS_TARGET` environment variable.

  Recognized values: `"local"`, `"fly"`, `"e2b"`. Unrecognized values fall back
  to `AgentOS.Providers.Local`.
  """
  @spec resolve_from_env() :: module()
  def resolve_from_env do
    case System.get_env("AGENT_OS_TARGET") do
      nil -> AgentOS.Providers.Local
      target -> resolve(String.to_existing_atom(target))
    end
  rescue
    ArgumentError -> AgentOS.Providers.Local
  end

  @doc """
  Returns all registered provider name/module pairs.

  ## Examples

      iex> AgentOS.Providers.Resolver.available_providers()
      [fly: AgentOS.Providers.Fly, local: AgentOS.Providers.Local]
  """
  @spec available_providers() :: [{atom(), module()}]
  def available_providers do
    @providers
    |> Map.to_list()
    |> Enum.sort_by(fn {name, _} -> name end)
  end
end
