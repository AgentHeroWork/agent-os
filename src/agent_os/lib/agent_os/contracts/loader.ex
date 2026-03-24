defmodule AgentOS.Contracts.Loader do
  @moduledoc """
  Loads contract specifications from YAML files, registered names, or maps.

  Contracts are stored as YAML in `priv/contracts/` and can be loaded by name.
  """

  alias AgentOS.Contracts.ContractSpec

  @contracts_dir Path.join(:code.priv_dir(:agent_os), "contracts")

  @doc """
  Loads a contract by name (from priv/contracts/), path, or map.

  ## Examples

      Loader.load("research-report")     # loads priv/contracts/research-report.yaml
      Loader.load("/path/to/contract.yaml")
      Loader.load(%{name: "custom", stages: [...]})
  """
  @spec load(String.t() | map()) :: {:ok, ContractSpec.t()} | {:error, term()}
  def load(name) when is_binary(name) do
    # Try as a registered contract name first
    yaml_path = Path.join(@contracts_dir, "#{name}.yaml")
    yml_path = Path.join(@contracts_dir, "#{name}.yml")

    cond do
      File.exists?(yaml_path) -> load_yaml(yaml_path)
      File.exists?(yml_path) -> load_yaml(yml_path)
      File.exists?(name) -> load_yaml(name)
      true -> {:error, {:contract_not_found, name}}
    end
  end

  def load(map) when is_map(map) do
    ContractSpec.from_map(map)
  end

  @doc """
  Lists all available contract names from priv/contracts/.
  """
  @spec list() :: [String.t()]
  def list do
    case File.ls(@contracts_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".yaml") or String.ends_with?(&1, ".yml")))
        |> Enum.map(&Path.rootname/1)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp load_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} -> ContractSpec.from_map(map)
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  end
end
