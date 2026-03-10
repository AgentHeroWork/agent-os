defmodule MemoryLayer.Schema do
  @moduledoc """
  Schema definitions and registry for the Memory Layer type system.

  Implements the schema category S where objects are typed schemas and
  morphisms are schema transformations. Each schema carries a `schema_name`
  tag (the _schema_name ClassVar equivalent from the Python reference)
  that enables runtime type resolution via the SchemaRegistry.

  ## The 24 Memory Types

  Organized into five subcategories:

    * **Core**: FACT, DECISION, PROCEDURAL, EPISODIC
    * **Extended**: TODO, ISSUE, API, SCHEMA
    * **Workflow**: WORKFLOW, TASK, STEP, AGENT_RUN
    * **Metadata**: TAG, ANNOTATION, EMBEDDING, INDEX
    * **System**: CONFIG, SESSION, CONTEXT, LOG
    * **Relational**: PERSON, PROJECT, ARTIFACT, EVENT

  ## Type Safety

  Type safety is enforced at two levels:

    1. **Compile-time**: Dialyzer typespecs catch type mismatches
    2. **Runtime**: Struct enforcement and validation in create/wrap

  Categorically, the SchemaRegistry is a section of the forgetful functor
  U: S → Set that sends each schema to its name string.
  """

  @typedoc "All 24 memory type atoms in the schema category."
  @type memory_type ::
          :fact
          | :decision
          | :procedural
          | :episodic
          | :todo
          | :issue
          | :api
          | :schema_def
          | :workflow
          | :task
          | :step
          | :agent_run
          | :tag
          | :annotation
          | :embedding
          | :index
          | :config
          | :session
          | :context
          | :log
          | :person
          | :project
          | :artifact
          | :event

  @typedoc "The subcategory a memory type belongs to."
  @type subcategory :: :core | :extended | :workflow | :metadata | :system | :relational

  @doc "Returns the subcategory for a given memory type."
  @spec subcategory(memory_type()) :: subcategory()
  def subcategory(type) when type in [:fact, :decision, :procedural, :episodic], do: :core
  def subcategory(type) when type in [:todo, :issue, :api, :schema_def], do: :extended
  def subcategory(type) when type in [:workflow, :task, :step, :agent_run], do: :workflow
  def subcategory(type) when type in [:tag, :annotation, :embedding, :index], do: :metadata
  def subcategory(type) when type in [:config, :session, :context, :log], do: :system
  def subcategory(type) when type in [:person, :project, :artifact, :event], do: :relational

  @doc "Returns all 24 memory types."
  @spec all_types() :: [memory_type()]
  def all_types do
    [
      :fact, :decision, :procedural, :episodic,
      :todo, :issue, :api, :schema_def,
      :workflow, :task, :step, :agent_run,
      :tag, :annotation, :embedding, :index,
      :config, :session, :context, :log,
      :person, :project, :artifact, :event
    ]
  end

  # ── Base Schema ──────────────────────────────────────────────

  defmodule BaseSchema do
    @moduledoc """
    The universal schema — initial object in the schema category S.

    Every domain schema embeds from BaseSchema via inheritance. The
    `schema_name` field acts as the tagging morphism that distinguishes
    objects in the category.
    """

    @enforce_keys [:schema_name, :content]
    defstruct [
      :schema_name,
      :content,
      :metadata,
      id: nil,
      created_at: nil,
      updated_at: nil,
      deleted_at: nil,
      content_hash: nil,
      tags: []
    ]

    @type t :: %__MODULE__{
            schema_name: String.t(),
            content: map(),
            metadata: map() | nil,
            id: String.t() | nil,
            created_at: DateTime.t() | nil,
            updated_at: DateTime.t() | nil,
            deleted_at: DateTime.t() | nil,
            content_hash: String.t() | nil,
            tags: [String.t()]
          }
  end

  # ── Core Schemas ─────────────────────────────────────────────

  defmodule FactData do
    @moduledoc "Schema for declarative knowledge: verified assertions with confidence."

    @enforce_keys [:assertion]
    defstruct [
      :assertion,
      :evidence,
      :source,
      confidence: 1.0,
      schema_name: "fact"
    ]

    @type t :: %__MODULE__{
            assertion: String.t(),
            evidence: String.t() | nil,
            source: String.t() | nil,
            confidence: float(),
            schema_name: String.t()
          }
  end

  defmodule DecisionData do
    @moduledoc "Schema for decision records with rationale and alternatives considered."

    @enforce_keys [:decision, :rationale]
    defstruct [
      :decision,
      :rationale,
      :alternatives,
      :context,
      confidence: 1.0,
      schema_name: "decision"
    ]

    @type t :: %__MODULE__{
            decision: String.t(),
            rationale: String.t(),
            alternatives: [String.t()] | nil,
            context: map() | nil,
            confidence: float(),
            schema_name: String.t()
          }
  end

  defmodule ProceduralData do
    @moduledoc "Schema for how-to knowledge: steps, preconditions, and postconditions."

    @enforce_keys [:name, :steps]
    defstruct [
      :name,
      :steps,
      :preconditions,
      :postconditions,
      :warnings,
      schema_name: "procedural"
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            steps: [String.t()],
            preconditions: [String.t()] | nil,
            postconditions: [String.t()] | nil,
            warnings: [String.t()] | nil,
            schema_name: String.t()
          }
  end

  defmodule EpisodicData do
    @moduledoc "Schema for experiential records: what happened, when, in what context."

    @enforce_keys [:event, :outcome]
    defstruct [
      :event,
      :outcome,
      :context,
      :participants,
      :duration_ms,
      occurred_at: nil,
      schema_name: "episodic"
    ]

    @type t :: %__MODULE__{
            event: String.t(),
            outcome: atom(),
            context: map() | nil,
            participants: [String.t()] | nil,
            duration_ms: non_neg_integer() | nil,
            occurred_at: DateTime.t() | nil,
            schema_name: String.t()
          }
  end

  # ── Extended Schemas ─────────────────────────────────────────

  defmodule TodoData do
    @moduledoc "Schema for action items with priority and status tracking."

    @enforce_keys [:title]
    defstruct [
      :title,
      :description,
      :assignee,
      priority: :medium,
      status: :pending,
      due_at: nil,
      schema_name: "todo"
    ]

    @type t :: %__MODULE__{
            title: String.t(),
            description: String.t() | nil,
            assignee: String.t() | nil,
            priority: :low | :medium | :high | :critical,
            status: :pending | :in_progress | :done | :cancelled,
            due_at: DateTime.t() | nil,
            schema_name: String.t()
          }
  end

  defmodule IssueData do
    @moduledoc "Schema for problem records with severity and resolution tracking."

    @enforce_keys [:title, :severity]
    defstruct [
      :title,
      :severity,
      :description,
      :resolution,
      :root_cause,
      status: :open,
      schema_name: "issue"
    ]

    @type t :: %__MODULE__{
            title: String.t(),
            severity: :low | :medium | :high | :critical,
            description: String.t() | nil,
            resolution: String.t() | nil,
            root_cause: String.t() | nil,
            status: :open | :investigating | :resolved | :closed,
            schema_name: String.t()
          }
  end

  defmodule WorkflowData do
    @moduledoc "Schema for end-to-end process definitions."

    @enforce_keys [:name, :steps]
    defstruct [
      :name,
      :steps,
      :description,
      :trigger,
      status: :defined,
      schema_name: "workflow"
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            steps: [String.t()],
            description: String.t() | nil,
            trigger: String.t() | nil,
            status: :defined | :running | :completed | :failed,
            schema_name: String.t()
          }
  end

  defmodule AgentRunData do
    @moduledoc "Schema for execution traces of agent invocations."

    @enforce_keys [:agent_id, :task]
    defstruct [
      :agent_id,
      :task,
      :result,
      :error,
      :input,
      :output,
      :duration_ms,
      :model,
      status: :running,
      started_at: nil,
      completed_at: nil,
      schema_name: "agent_run"
    ]

    @type t :: %__MODULE__{
            agent_id: String.t(),
            task: String.t(),
            result: term() | nil,
            error: String.t() | nil,
            input: map() | nil,
            output: map() | nil,
            duration_ms: non_neg_integer() | nil,
            model: String.t() | nil,
            status: :running | :completed | :failed | :cancelled,
            started_at: DateTime.t() | nil,
            completed_at: DateTime.t() | nil,
            schema_name: String.t()
          }
  end

  # ── Schema Registry (GenServer) ─────────────────────────────

  defmodule Registry do
    @moduledoc """
    Runtime schema type resolution — a section of the forgetful functor U: S → Set.

    Maps schema name strings to their corresponding module, enabling type-safe
    deserialization: given a stored `schema_name`, the registry returns the
    struct module to deserialize into.

    ## Categorical Interpretation

    The registry is injective by construction (schema names are unique),
    ensuring unambiguous type resolution:

        SchemaRegistry: Names ↪ S,  U ∘ SchemaRegistry = id_Names
    """

    use GenServer

    @type registry_state :: %{String.t() => module()}

    # ── Client API ───────────────────────────────────────────

    @doc "Start the schema registry GenServer."
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @doc "Resolve a schema name to its module. Returns {:ok, module} or {:error, :not_found}."
    @spec resolve(String.t()) :: {:ok, module()} | {:error, :not_found}
    def resolve(schema_name) do
      GenServer.call(__MODULE__, {:resolve, schema_name})
    end

    @doc "Register a new schema module under the given name."
    @spec register(String.t(), module()) :: :ok
    def register(schema_name, module) do
      GenServer.call(__MODULE__, {:register, schema_name, module})
    end

    @doc "List all registered schema names."
    @spec list() :: [String.t()]
    def list do
      GenServer.call(__MODULE__, :list)
    end

    # ── GenServer Callbacks ──────────────────────────────────

    @impl true
    @spec init(keyword()) :: {:ok, registry_state()}
    def init(_opts) do
      registry = %{
        "fact" => MemoryLayer.Schema.FactData,
        "decision" => MemoryLayer.Schema.DecisionData,
        "procedural" => MemoryLayer.Schema.ProceduralData,
        "episodic" => MemoryLayer.Schema.EpisodicData,
        "todo" => MemoryLayer.Schema.TodoData,
        "issue" => MemoryLayer.Schema.IssueData,
        "workflow" => MemoryLayer.Schema.WorkflowData,
        "agent_run" => MemoryLayer.Schema.AgentRunData
      }

      {:ok, registry}
    end

    @impl true
    def handle_call({:resolve, schema_name}, _from, state) do
      case Map.fetch(state, schema_name) do
        {:ok, module} -> {:reply, {:ok, module}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    @impl true
    def handle_call({:register, schema_name, module}, _from, state) do
      {:reply, :ok, Map.put(state, schema_name, module)}
    end

    @impl true
    def handle_call(:list, _from, state) do
      {:reply, Map.keys(state), state}
    end
  end
end
