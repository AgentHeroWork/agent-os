defmodule AgentOS.Contracts.Verify do
  @moduledoc """
  Generic artifact verification for data-driven contracts.

  Interprets verification rules from a `ContractSpec` and checks artifacts
  against them. This replaces the need for per-contract `verify/1` callbacks
  when using data-driven contracts.

  ## Rule Types

    * `{:file_exists, path}` — artifact path must exist on disk
    * `{:min_bytes, path, size}` — file must be at least `size` bytes
    * `{:key_present, key}` — artifact map must have non-nil value for `key`
  """

  @doc """
  Verifies artifacts against a list of rules.

  Returns `:ok` if all rules pass, or `{:retry, reason}` on the first failure.
  """
  @spec check(map(), [AgentOS.Contracts.ContractSpec.verify_rule()]) :: :ok | {:retry, String.t()}
  def check(_artifacts, []), do: :ok

  def check(artifacts, [rule | rest]) do
    case check_rule(artifacts, rule) do
      :ok -> check(artifacts, rest)
      {:retry, _} = failure -> failure
    end
  end

  defp check_rule(artifacts, {:file_exists, path_key}) do
    path = resolve_path(artifacts, path_key)

    cond do
      is_nil(path) -> {:retry, "Artifact '#{path_key}' is nil"}
      not File.exists?(path) -> {:retry, "File does not exist: #{path}"}
      true -> :ok
    end
  end

  defp check_rule(artifacts, {:min_bytes, path_key, min_size}) do
    path = resolve_path(artifacts, path_key)

    cond do
      is_nil(path) ->
        {:retry, "Artifact '#{path_key}' is nil"}

      not File.exists?(path) ->
        {:retry, "File does not exist: #{path}"}

      true ->
        case File.stat(path) do
          {:ok, %{size: size}} when size >= min_size -> :ok
          {:ok, %{size: size}} -> {:retry, "File '#{path_key}' is #{size} bytes (min: #{min_size})"}
          _ -> {:retry, "Cannot stat file: #{path}"}
        end
    end
  end

  defp check_rule(artifacts, {:key_present, key}) do
    val = Map.get(artifacts, key)

    if is_nil(val) or val == "" or val == [] do
      {:retry, "Required artifact '#{key}' is missing or empty"}
    else
      :ok
    end
  end

  defp check_rule(_artifacts, _unknown_rule), do: :ok

  # Resolve a path key — could be a string filename or an atom key in the artifacts map
  defp resolve_path(artifacts, key) when is_atom(key), do: Map.get(artifacts, key)

  defp resolve_path(artifacts, key) when is_binary(key) do
    # Try as atom key first, then look in output_dir
    atom_key = String.to_atom(String.replace(key, ~r/[^a-z0-9_]/, "_"))

    case Map.get(artifacts, atom_key) do
      nil ->
        # Check if it's a relative path in the output directory
        output_dir = Map.get(artifacts, :output_dir)
        if output_dir, do: Path.join(output_dir, key), else: nil

      path ->
        path
    end
  end
end
