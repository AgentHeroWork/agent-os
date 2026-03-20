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
    case File.read(path) do
      {:ok, content} ->
        case parse_yaml(content) do
          {:ok, map} -> ContractSpec.from_map(map)
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, {:file_read_error, path, reason}}
    end
  end

  # Simple YAML parser — handles the subset we need (no external deps)
  # Supports: scalars, lists, nested maps, multi-line strings
  defp parse_yaml(content) do
    try do
      result =
        content
        |> String.split("\n")
        |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
        |> parse_yaml_lines(0)
        |> elem(0)

      {:ok, result}
    rescue
      e -> {:error, {:yaml_parse_error, Exception.message(e)}}
    end
  end

  defp parse_yaml_lines([], _indent), do: {%{}, []}

  defp parse_yaml_lines([line | rest], min_indent) do
    stripped = String.trim_leading(line)
    current_indent = String.length(line) - String.length(stripped)

    if current_indent < min_indent do
      {%{}, [line | rest]}
    else
      case parse_yaml_line(stripped) do
        {:key_value, key, value} ->
          {rest_map, remaining} = parse_yaml_lines(rest, min_indent)
          {Map.put(rest_map, key, value), remaining}

        {:key_map, key} ->
          {nested, remaining} = parse_yaml_lines(rest, current_indent + 2)
          {rest_map, remaining2} = parse_yaml_lines(remaining, min_indent)
          {Map.put(rest_map, key, nested), remaining2}

        {:key_list_start, key} ->
          {list, remaining} = parse_yaml_list(rest, current_indent + 2)
          {rest_map, remaining2} = parse_yaml_lines(remaining, min_indent)
          {Map.put(rest_map, key, list), remaining2}

        {:list_item, _value} ->
          # We hit a list item at the map level — collect as a list
          {list, remaining} = parse_yaml_list([line | rest], current_indent)
          {list, remaining}

        {:multiline_start, key} ->
          {text, remaining} = collect_multiline(rest, current_indent + 2)
          {rest_map, remaining2} = parse_yaml_lines(remaining, min_indent)
          {Map.put(rest_map, key, text), remaining2}

        :skip ->
          parse_yaml_lines(rest, min_indent)
      end
    end
  end

  defp parse_yaml_line("- " <> value), do: {:list_item, parse_scalar(String.trim(value))}

  defp parse_yaml_line(line) do
    case String.split(line, ":", parts: 2) do
      [key, " |"] -> {:multiline_start, String.trim(key)}
      [key, " [" <> _rest] -> {:key_list_start, String.trim(key)}
      [key, ""] -> {:key_map, String.trim(key)}
      [key, value] ->
        trimmed = String.trim(value)
        if trimmed == "" do
          {:key_map, String.trim(key)}
        else
          {:key_value, String.trim(key), parse_scalar(trimmed)}
        end
      _ -> :skip
    end
  end

  defp parse_scalar("'" <> rest), do: String.trim_trailing(rest, "'")
  defp parse_scalar("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false

  defp parse_scalar(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> val
    end
  end

  defp parse_yaml_list([], _indent), do: {[], []}

  defp parse_yaml_list([line | rest], min_indent) do
    stripped = String.trim_leading(line)
    current_indent = String.length(line) - String.length(stripped)

    if current_indent < min_indent or not String.starts_with?(stripped, "- ") do
      {[], [line | rest]}
    else
      value = stripped |> String.trim_leading("- ") |> String.trim()

      if String.contains?(value, ":") and not String.starts_with?(value, "'") do
        # List of maps — parse inline map
        {nested, remaining} =
          if value == "" do
            parse_yaml_lines(rest, current_indent + 2)
          else
            # Inline key: value after "- "
            {map, rem} = parse_yaml_lines([String.duplicate(" ", current_indent + 2) <> value | rest], current_indent + 2)
            {map, rem}
          end

        {rest_list, remaining2} = parse_yaml_list(remaining, min_indent)
        {[nested | rest_list], remaining2}
      else
        {rest_list, remaining} = parse_yaml_list(rest, min_indent)
        {[parse_scalar(value) | rest_list], remaining}
      end
    end
  end

  defp collect_multiline([], _indent), do: {"", []}

  defp collect_multiline([line | rest], min_indent) do
    stripped = String.trim_leading(line)
    current_indent = String.length(line) - String.length(stripped)

    if current_indent < min_indent and stripped != "" do
      {"", [line | rest]}
    else
      {rest_text, remaining} = collect_multiline(rest, min_indent)
      text = if rest_text == "", do: stripped, else: stripped <> "\n" <> rest_text
      {text, remaining}
    end
  end
end
