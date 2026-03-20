defmodule AgentOS.Contracts.ContractSpec do
  @moduledoc """
  Data-driven contract specification.

  Unlike module-based contracts (which implement the `Contract` behaviour),
  a ContractSpec is a struct built from maps or YAML. This allows users to
  define contracts as data without writing Elixir code.

  ## Example

      %ContractSpec{
        name: "research-report",
        stages: [
          %{name: :researcher, instructions: "Research the topic...", output: ["findings.md"]},
          %{name: :writer, instructions: "Write LaTeX paper...", input_from: :researcher, output: ["paper.tex"]},
          %{name: :publisher, instructions: "Push to GitHub...", input_from: :writer, output: ["repo_url.txt"]}
        ],
        required_artifacts: [:findings_md, :paper_tex, :repo_url],
        verify: [
          {:file_exists, "findings.md"},
          {:min_bytes, "paper.tex", 500}
        ],
        max_retries: 2
      }
  """

  @type stage :: %{
          name: atom(),
          instructions: String.t(),
          output: [String.t()],
          input_from: atom() | [atom()] | nil,
          image: String.t() | nil,
          tools: [atom()] | nil
        }

  @type verify_rule ::
          {:file_exists, String.t()}
          | {:min_bytes, String.t(), pos_integer()}
          | {:key_present, atom()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          stages: [stage()],
          required_artifacts: [atom()],
          verify: [verify_rule()],
          max_retries: non_neg_integer(),
          credentials: [atom()],
          memory: map(),
          resources: map()
        }

  defstruct [
    :name,
    :description,
    stages: [],
    required_artifacts: [],
    verify: [],
    max_retries: 2,
    credentials: [],
    memory: %{
      load_past_runs: 5,
      load_procedures: 3,
      knowledge_base: false,
      search_mode: :semantic,
      backends: [:mnesia, :contextfs]
    },
    resources: %{
      memory_mb: 512,
      cpus: 1,
      timeout_ms: 300_000
    }
  ]

  @doc """
  Builds a ContractSpec from a plain map (e.g., parsed from YAML or JSON).

  String keys are converted to atoms. Stages are normalized to maps with
  atom keys. Returns `{:ok, spec}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs) do
    with {:ok, name} <- require_field(attrs, "name"),
         stages <- parse_stages(attrs),
         artifacts <- parse_artifacts(attrs),
         verify_rules <- parse_verify(attrs) do
      spec = %__MODULE__{
        name: name,
        description: get_string(attrs, "description"),
        stages: stages,
        required_artifacts: artifacts,
        verify: verify_rules,
        max_retries: get_integer(attrs, "max_retries", 2),
        credentials: parse_atom_list(attrs, "credentials"),
        memory: parse_memory(attrs),
        resources: parse_resources(attrs)
      }

      {:ok, spec}
    end
  end

  def from_map(_), do: {:error, :invalid_attrs}

  @doc """
  Returns required_artifacts as a list of atoms.
  Implements the same interface as module-based contracts.
  """
  @spec required_artifacts(t()) :: [atom()]
  def required_artifacts(%__MODULE__{required_artifacts: artifacts}), do: artifacts

  @doc """
  Returns max_retries.
  """
  @spec max_retries(t()) :: non_neg_integer()
  def max_retries(%__MODULE__{max_retries: n}), do: n

  @doc """
  Checks if this is a multi-stage pipeline contract (has stages defined).
  """
  @spec pipeline?(t()) :: boolean()
  def pipeline?(%__MODULE__{stages: stages}), do: length(stages) > 0

  # -- Parsing Helpers --

  defp require_field(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      nil -> {:error, {:missing_required, key}}
      val -> {:ok, to_string(val)}
    end
  end

  defp get_string(attrs, key, default \\ nil) do
    val = Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
    if val, do: to_string(val), else: default
  end

  defp get_integer(attrs, key, default) do
    val = Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

    case val do
      n when is_integer(n) -> n
      s when is_binary(s) -> String.to_integer(s)
      _ -> default
    end
  end

  defp parse_stages(attrs) do
    raw = Map.get(attrs, "stages") || Map.get(attrs, :stages, [])

    Enum.map(raw, fn stage ->
      %{
        name: atomize(stage["name"] || stage[:name] || "default"),
        instructions: to_string(stage["instructions"] || stage[:instructions] || ""),
        output: List.wrap(stage["output"] || stage[:output] || []),
        input_from: parse_input_from(stage["input_from"] || stage[:input_from]),
        image: stage["image"] || stage[:image],
        tools: parse_atom_list_raw(stage["tools"] || stage[:tools] || [])
      }
    end)
  end

  defp parse_input_from(nil), do: nil
  defp parse_input_from(val) when is_atom(val), do: val
  defp parse_input_from(val) when is_binary(val), do: String.to_atom(val)
  defp parse_input_from(list) when is_list(list), do: Enum.map(list, &atomize/1)

  defp parse_artifacts(attrs) do
    raw = Map.get(attrs, "required_artifacts") || Map.get(attrs, :required_artifacts, [])
    Enum.map(raw, &atomize/1)
  end

  defp parse_verify(attrs) do
    raw = Map.get(attrs, "verify") || Map.get(attrs, :verify, [])

    Enum.map(raw, fn
      %{"file_exists" => path} -> {:file_exists, path}
      %{"min_bytes" => path, "size" => size} -> {:min_bytes, path, size}
      %{"key_present" => key} -> {:key_present, atomize(key)}
      {:file_exists, path} -> {:file_exists, path}
      {:min_bytes, path, size} -> {:min_bytes, path, size}
      {:key_present, key} -> {:key_present, key}
      other -> other
    end)
  end

  defp parse_memory(attrs) do
    raw = Map.get(attrs, "memory") || Map.get(attrs, :memory, %{})

    %{
      load_past_runs: get_integer(raw, "load_past_runs", 5),
      load_procedures: get_integer(raw, "load_procedures", 3),
      knowledge_base: raw["knowledge_base"] || raw[:knowledge_base] || false,
      search_mode: atomize(raw["search_mode"] || raw[:search_mode] || "semantic"),
      backends: parse_atom_list_raw(raw["backends"] || raw[:backends] || [:mnesia, :contextfs])
    }
  end

  defp parse_resources(attrs) do
    raw = Map.get(attrs, "resources") || Map.get(attrs, :resources, %{})

    %{
      memory_mb: get_integer(raw, "memory_mb", 512),
      cpus: get_integer(raw, "cpus", 1),
      timeout_ms: get_integer(raw, "timeout_ms", 300_000)
    }
  end

  defp parse_atom_list(attrs, key) do
    raw = Map.get(attrs, key) || Map.get(attrs, String.to_atom(key), [])
    parse_atom_list_raw(raw)
  end

  defp parse_atom_list_raw(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp parse_atom_list_raw(_), do: []

  defp atomize(val) when is_atom(val), do: val
  defp atomize(val) when is_binary(val), do: String.to_atom(val)
  defp atomize(val), do: val
end
