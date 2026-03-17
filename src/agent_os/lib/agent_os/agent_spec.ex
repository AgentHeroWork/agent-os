defmodule AgentOS.AgentSpec do
  @moduledoc """
  Complete specification for creating and running an agent.

  An AgentSpec bundles the agent type, configuration, credentials, and
  completion requirements into a single validated structure.
  """

  @type llm_config :: %{
          model: String.t(),
          temperature: float(),
          max_tokens: non_neg_integer(),
          provider: :openai | :anthropic | :ollama
        }

  @type t :: %__MODULE__{
          type: atom(),
          name: String.t(),
          oversight: :supervised | :spot_check | :autonomous_escalation,
          credentials: AgentOS.Credentials.credential_set(),
          completion: completion_config(),
          resources: resource_config(),
          llm_config: llm_config(),
          provider: atom(),
          metadata: map()
        }

  @type completion_config :: %{
          pipeline:
            [:write_latex | :compile_pdf | :ensure_repo | :generate_readme | :push_artifacts],
          repo_org: String.t(),
          repo_prefix: String.t() | nil
        }

  @type resource_config :: %{
          cpu: String.t(),
          memory: String.t(),
          timeout_ms: non_neg_integer()
        }

  defstruct [
    :type,
    :name,
    oversight: :autonomous_escalation,
    credentials: %{},
    completion: %{
      pipeline: [:write_latex, :compile_pdf, :ensure_repo, :generate_readme, :push_artifacts],
      repo_org: "AgentHeroWork",
      repo_prefix: nil
    },
    resources: %{
      cpu: "shared-cpu-1x",
      memory: "256mb",
      # 30 minutes
      timeout_ms: 1_800_000
    },
    llm_config: %{
      model: "gpt-4o",
      temperature: 0.7,
      max_tokens: 4096,
      provider: :openai
    },
    provider: :local,
    metadata: %{}
  ]

  @known_agent_types [:open_claw, :nemo_claw, :generic]

  @doc "Creates a new AgentSpec from a map, validating required fields."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, type} <- fetch_required(attrs, :type),
         {:ok, name} <- fetch_required(attrs, :name) do
      spec = %__MODULE__{
        type: type,
        name: name,
        oversight: Map.get(attrs, :oversight, :autonomous_escalation),
        credentials: Map.get(attrs, :credentials, %{}),
        completion: Map.get(attrs, :completion, %__MODULE__{}.completion),
        resources: Map.get(attrs, :resources, %__MODULE__{}.resources),
        llm_config: Map.get(attrs, :llm_config, %__MODULE__{}.llm_config),
        provider: Map.get(attrs, :provider, :local),
        metadata: Map.get(attrs, :metadata, %{})
      }

      {:ok, spec}
    end
  end

  def new(_), do: {:error, :invalid_attrs}

  @doc "Validates the spec: type must be registered, credentials must be sufficient."
  @spec validate(t()) :: :ok | {:error, [term()]}
  def validate(%__MODULE__{} = spec) do
    errors =
      []
      |> validate_type(spec.type)
      |> validate_credentials(spec.type, spec.credentials)

    case errors do
      [] -> :ok
      list -> {:error, list}
    end
  end

  @doc "Resolves credentials for this spec (merges explicit with env/config)."
  @spec resolve_credentials(t()) :: t()
  def resolve_credentials(%__MODULE__{} = spec) do
    resolved = AgentOS.Credentials.resolve(spec.credentials)
    %{spec | credentials: resolved}
  end

  # Private helpers

  defp fetch_required(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:error, {:missing_required, key}}
      value -> {:ok, value}
    end
  end

  defp validate_type(errors, type) do
    if type in @known_agent_types do
      errors
    else
      [{:unknown_agent_type, type} | errors]
    end
  end

  defp validate_credentials(errors, type, credentials) do
    case AgentOS.Credentials.validate_for_agent(type, credentials) do
      :ok -> errors
      {:error, missing} -> [{:missing_credentials, missing} | errors]
    end
  end
end
