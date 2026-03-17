defmodule AgentOS.Credentials do
  @moduledoc """
  Credential management for agent execution.

  Agents need credentials to interact with external services (GitHub, APIs).
  This module resolves credentials from multiple sources with a priority chain:

  1. Explicit credentials in the agent spec
  2. Config file: ~/.agent-os/credentials.toml (if exists)
  3. Environment variables
  4. Local tool integration (e.g., `gh auth token` for GitHub)

  Credentials are never logged or persisted in plaintext by the system.
  """

  @type credential_set :: %{
          github_token: String.t() | nil,
          agent_os_api_key: String.t() | nil,
          fly_api_token: String.t() | nil,
          openai_api_key: String.t() | nil,
          anthropic_api_key: String.t() | nil,
          custom: %{String.t() => String.t()}
        }

  @doc """
  Resolves all credentials for an agent, merging from all sources.
  Explicit creds override config file override env vars override local tools.
  """
  @spec resolve(map()) :: credential_set()
  def resolve(explicit_creds \\ %{}) do
    local = local_tool_creds()
    env = env_creds()
    config = read_config_file()

    base = %{
      github_token: nil,
      agent_os_api_key: nil,
      fly_api_token: nil,
      openai_api_key: nil,
      anthropic_api_key: nil,
      custom: %{}
    }

    base
    |> merge_creds(local)
    |> merge_creds(env)
    |> merge_creds(config)
    |> merge_creds(explicit_creds)
  end

  @doc """
  Resolves GitHub token specifically.
  Falls back to calling `gh auth token` via System.cmd if no env var set.
  """
  @spec github_token(map()) :: String.t() | nil
  def github_token(explicit_creds \\ %{}) do
    cond do
      Map.has_key?(explicit_creds, :github_token) && explicit_creds[:github_token] ->
        explicit_creds[:github_token]

      token = System.get_env("GITHUB_TOKEN") ->
        token

      true ->
        gh_auth_token()
    end
  end

  @doc """
  Reads credentials from ~/.agent-os/credentials.toml if it exists.

  Format:
    [github]
    token = "ghp_..."

    [fly]
    token = "..."

    [agent_os]
    api_key = "..."

    [custom]
    my_service = "key_123"
  """
  @spec read_config_file() :: map()
  def read_config_file do
    path = Path.expand("~/.agent-os/credentials.toml")

    if File.exists?(path) do
      parse_toml(path)
    else
      %{}
    end
  end

  @doc """
  Validates that required credentials are present for a given agent type.

  OpenClaw needs: github_token (for repo pushing)
  NemoClaw needs: github_token (for repo pushing)
  Both need agent_os_api_key if running remotely.

  Returns :ok or {:error, [missing_credential_names]}
  """
  @spec validate_for_agent(atom(), credential_set()) :: :ok | {:error, [atom()]}
  def validate_for_agent(agent_type, creds) do
    required = required_creds_for(agent_type)

    missing =
      Enum.filter(required, fn key ->
        is_nil(Map.get(creds, key))
      end)

    case missing do
      [] -> :ok
      list -> {:error, list}
    end
  end

  @doc """
  Returns a sanitized version of credentials (tokens masked) for logging.
  """
  @spec sanitize(credential_set()) :: map()
  def sanitize(creds) do
    creds
    |> Map.take([:github_token, :agent_os_api_key, :fly_api_token, :openai_api_key, :anthropic_api_key, :custom])
    |> Enum.map(fn
      {:custom, custom_map} when is_map(custom_map) ->
        {:custom, Map.new(custom_map, fn {k, v} -> {k, mask(v)} end)}

      {key, nil} ->
        {key, nil}

      {key, value} ->
        {key, mask(value)}
    end)
    |> Map.new()
  end

  # Private helpers

  defp merge_creds(base, overrides) when is_map(overrides) do
    custom =
      Map.merge(
        Map.get(base, :custom, %{}),
        Map.get(overrides, :custom, %{})
      )

    base
    |> maybe_override(:github_token, overrides)
    |> maybe_override(:agent_os_api_key, overrides)
    |> maybe_override(:fly_api_token, overrides)
    |> maybe_override(:openai_api_key, overrides)
    |> maybe_override(:anthropic_api_key, overrides)
    |> Map.put(:custom, custom)
  end

  defp maybe_override(base, key, overrides) do
    case Map.get(overrides, key) do
      nil -> base
      value -> Map.put(base, key, value)
    end
  end

  defp env_creds do
    %{}
    |> maybe_put_env(:github_token, "GITHUB_TOKEN")
    |> maybe_put_env(:agent_os_api_key, "AGENT_OS_API_KEY")
    |> maybe_put_env(:fly_api_token, "FLY_API_TOKEN")
    |> maybe_put_env(:openai_api_key, "OPENAI_API_KEY")
    |> maybe_put_env(:anthropic_api_key, "ANTHROPIC_API_KEY")
  end

  defp maybe_put_env(map, key, env_var) do
    case System.get_env(env_var) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp local_tool_creds do
    case gh_auth_token() do
      nil -> %{}
      token -> %{github_token: token}
    end
  end

  defp gh_auth_token do
    try do
      case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
        {token, 0} -> String.trim(token)
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp required_creds_for(:open_claw), do: [:github_token]
  defp required_creds_for(:nemo_claw), do: [:github_token]
  defp required_creds_for(_), do: []

  @doc "Resolves the best available LLM API key and provider from credentials."
  @spec llm_config(credential_set()) :: {atom(), String.t() | nil}
  def llm_config(creds) do
    cond do
      creds[:openai_api_key] -> {:openai, creds[:openai_api_key]}
      creds[:anthropic_api_key] -> {:anthropic, creds[:anthropic_api_key]}
      true -> {:ollama, nil}
    end
  end

  defp mask(value) when is_binary(value) and byte_size(value) > 8 do
    String.slice(value, 0, 4) <> "****" <> String.slice(value, -4, 4)
  end

  defp mask(value) when is_binary(value), do: "****"
  defp mask(_), do: "****"

  defp parse_toml(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, current_section} ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          {acc, current_section}

        String.match?(line, ~r/^\[(.+)\]$/) ->
          [_, section] = Regex.run(~r/^\[(.+)\]$/, line)
          {acc, section}

        String.contains?(line, "=") and current_section != nil ->
          [key, value] = String.split(line, "=", parts: 2)
          key = String.trim(key)
          value = value |> String.trim() |> String.trim("\"")
          put_config_value(acc, current_section, key, value)

        true ->
          {acc, current_section}
      end
    end)
    |> elem(0)
  end

  defp put_config_value(acc, "github", "token", value),
    do: {Map.put(acc, :github_token, value), "github"}

  defp put_config_value(acc, "fly", "token", value),
    do: {Map.put(acc, :fly_api_token, value), "fly"}

  defp put_config_value(acc, "agent_os", "api_key", value),
    do: {Map.put(acc, :agent_os_api_key, value), "agent_os"}

  defp put_config_value(acc, "openai", "api_key", value),
    do: {Map.put(acc, :openai_api_key, value), "openai"}

  defp put_config_value(acc, "anthropic", "api_key", value),
    do: {Map.put(acc, :anthropic_api_key, value), "anthropic"}

  defp put_config_value(acc, "custom", key, value) do
    custom = Map.get(acc, :custom, %{})
    {Map.put(acc, :custom, Map.put(custom, key, value)), "custom"}
  end

  defp put_config_value(acc, section, _key, _value), do: {acc, section}
end
