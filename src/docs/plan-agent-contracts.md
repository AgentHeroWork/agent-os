# Feature Plan: Agent Contracts

## Current State

A contract is a behaviour with 3 callbacks:

```elixir
# AgentOS.Contracts.Contract
@callback required_artifacts() :: [atom()]
@callback verify(artifacts :: map()) :: :ok | {:retry, String.t()}
@callback max_retries() :: non_neg_integer()
```

Only one implementation exists: `AgentOS.Contracts.ResearchContract` (requires `:tex_path`, `:pdf_path`, `:repo_url`). The `AgentOS.AgentRunner` calls `agent_module.run_autonomous(input, context)`, validates artifacts against the contract, and retries on failure. That is the entire enforcement surface.

**What is missing:**

- Contracts only validate outputs. Nothing constrains execution (tool access, API calls, token spend).
- `ToolInterface.Capability` tokens exist but are never issued from contracts. The signing key is hardcoded.
- `ToolInterface.Audit` logs invocations but nothing reads the logs to enforce limits.
- `AgentOS.Credentials` resolves credentials globally. No per-contract scoping.
- `AgentOS.AgentSpec.@known_agent_types` is a hardcoded list (`[:open_claw, :nemo_claw, :generic]`).
- `AgentRunner.run/3` is synchronous and blocking. No checkpointing, no scheduled wakeup, no persistence across restarts.
- `AgentScheduler.Agents.Runtime` supports `:beam`, `:port`, `:docker`, `:fly` modes but none are wired to contract constraints.
- `PlannerEngine.Market` has its own contract concept (client/operator marketplace contracts with escrow) that is completely disconnected from execution contracts.

---

## Target Architecture

A contract becomes a runtime specification:

```
Contract = Artifacts + Permissions + Budget + Lifecycle + Auth + Strategy
```

Agents receive the full contract spec, plan their execution against it, and self-enforce within the guardrails. The system enforces hard limits (token budgets, tool access, timeouts) that agents cannot override.

---

## Phase 1: Replace the Hardcoded System

Goal: Make contracts data-driven. Any contract can specify what tools an agent may use, what credentials it gets, and what resources it can consume. Remove hardcoded agent types.

### 1.1 Contract Spec Struct

**What it does:** Define `AgentOS.Contracts.ContractSpec` as a struct that replaces the 3-callback behaviour with a declarative data structure. Fields: `id`, `name`, `version`, `required_artifacts` (list of `{name, type, validation_fn}`), `allowed_tools` (list of tool IDs or `:all`), `denied_tools` (list of tool IDs), `credential_scope` (map of credential keys the agent may access), `resource_budget` (token limit, compute timeout, max tool invocations), `max_retries`, `retry_delay_ms`, `metadata`.

**Why it matters:** Contracts become serializable data instead of compiled modules. You can store them in Mnesia, send them over the wire, and modify them at runtime. New contract types do not require code changes.

**Dependencies:** None. This is the foundation.

### 1.2 Tool Access Control via Contracts

**What it does:** When `AgentRunner` starts an agent, it reads `contract_spec.allowed_tools` and `contract_spec.denied_tools`, then calls `ToolInterface.Capability.create/5` to mint capability tokens scoped to exactly those tools. The agent receives only these tokens. `ToolInterface.Registry.freeze/0` is called after token minting so the tool set is locked for the execution.

**Why it matters:** Today agents can call any tool unlimited times. This gates tool access per-contract. A research contract gets `web-search`, `pdf-parse`, `generate-document` but not `shell-exec` or `code-exec`.

**Dependencies:** 1.1 (ContractSpec), existing `ToolInterface.Capability`, existing `ToolInterface.Registry`.

### 1.3 Resource Budget Enforcement

**What it does:** Add a `AgentOS.Contracts.BudgetEnforcer` GenServer that tracks per-execution resource consumption: LLM tokens used, tool invocations count, wall-clock time elapsed. `ToolInterface.Audit.log_invocation/6` already records every tool call; the enforcer subscribes to `[:tool_interface, :invocation]` telemetry events and increments counters. When a budget limit is hit, the enforcer sends `{:budget_exceeded, resource_type}` to the `AgentRunner` process, which triggers graceful shutdown or escalation.

**Why it matters:** Without budgets, a runaway agent can burn unlimited LLM tokens or make thousands of API calls. Budget enforcement is a hard safety boundary.

**Dependencies:** 1.1 (ContractSpec defines the budget), existing `ToolInterface.Audit` telemetry, existing `AgentRunner`.

### 1.4 Per-Contract Credential Scoping

**What it does:** Extend `AgentOS.Credentials.resolve/1` to accept an optional `credential_scope` from the contract spec. When a scope is provided, `resolve/1` returns only the credentials named in the scope, with all others set to `nil`. The agent's `build_context/2` in `AgentRunner` passes scoped credentials instead of the full set.

**Why it matters:** A contract that only needs GitHub access should not receive the OpenAI API key. Least-privilege credential access reduces blast radius if an agent is compromised.

**Dependencies:** 1.1 (ContractSpec defines the scope), existing `AgentOS.Credentials`.

### 1.5 Dynamic Agent Type Registry

**What it does:** Remove `@known_agent_types` from `AgentOS.AgentSpec`. Instead, `AgentSpec.validate/1` checks `AgentScheduler.Agents.Registry.lookup/1` to see if the type is registered. New agent types can be registered at runtime via `Registry.register/2` without code changes. The `AgentRunner.resolve_agent_module/1` function already falls back to the registry; remove the hardcoded pattern matches for `:open_claw` and `:nemo_claw`.

**Why it matters:** Agent types should not be compile-time constants. Third-party agents need to register themselves dynamically.

**Dependencies:** Existing `AgentScheduler.Agents.Registry`.

### 1.6 Contract Verification Overhaul

**What it does:** Replace the `AgentOS.Contracts.Contract` behaviour with a `verify/2` function on `ContractSpec` that takes the spec and the artifacts map. Verification rules are encoded as a list of `{field, validator_fn}` tuples in the spec, not as a callback module. Keep `ResearchContract` as a helper that returns a pre-built `ContractSpec` for backward compatibility.

**Why it matters:** Verification logic should live in the contract data, not in separate modules. This lets contracts define custom validators without new `.ex` files.

**Dependencies:** 1.1 (ContractSpec).

### 1.7 Capability Token Signing Key from Config

**What it does:** Move the `@signing_key` from `ToolInterface.Capability` module attribute to application config (`Application.get_env(:tool_interface, :signing_key)`). Default to the current hardcoded value in dev/test. Require explicit config in production.

**Why it matters:** Hardcoded signing keys are a security vulnerability. Rotating keys requires recompilation today.

**Dependencies:** None.

---

## Phase 2: Long-Running Agent Support

Goal: Agents can run for hours or days with checkpoint persistence, scheduled wakeups, and heartbeat monitoring.

### 2.1 Checkpoint Persistence (Mnesia)

**What it does:** Add a `:agent_checkpoints` Mnesia table with schema `{agent_id, contract_id, step_index, state_snapshot, artifacts_so_far, timestamp}`. `AgentRunner` writes a checkpoint after each successful step (tool call completion, artifact generation). On restart, `AgentRunner.resume/2` loads the latest checkpoint and resumes from that step.

**Why it matters:** Today if the BEAM node crashes, all agent state is lost. Research agents running 30-minute pipelines must restart from scratch. Checkpointing lets them resume.

**Dependencies:** Existing Mnesia infrastructure (see `PlannerEngine.Escrow.init_mnesia/0` for the pattern), Phase 1 ContractSpec.

### 2.2 Agent GenServer Lifecycle

**What it does:** Convert `AgentRunner` from a module with plain functions to a GenServer. Each running agent gets its own GenServer process under a `DynamicSupervisor`. The GenServer state holds: contract spec, current step, checkpoint reference, budget counters, capability tokens. The GenServer handles `:timeout` messages for scheduled wakeups and `:heartbeat` messages for liveness monitoring.

**Why it matters:** `AgentRunner.run/3` is currently a blocking function call. A GenServer gives each agent a proper OTP lifecycle: start, checkpoint, suspend, resume, stop. The supervisor tree restarts crashed agents automatically.

**Dependencies:** 2.1 (Checkpoints), existing `AgentOS.Application` supervision tree.

### 2.3 Scheduled Wakeups

**What it does:** Add a `:wakeup_schedule` field to `ContractSpec` — a list of `{:after_ms, milliseconds}` or `{:cron, cron_expression}` entries. The Agent GenServer uses `Process.send_after/3` for millisecond delays. For cron schedules, a lightweight `AgentOS.Contracts.CronScheduler` GenServer checks every minute and sends `:wakeup` to sleeping agents.

**Why it matters:** Multi-day agents need to sleep between phases. A research agent might: Phase 1 (write paper, 30 min) -> sleep 24 hours -> Phase 2 (check citations, 10 min) -> sleep 48 hours -> Phase 3 (submit to arXiv, 5 min).

**Dependencies:** 2.2 (Agent GenServer).

### 2.4 Heartbeat Monitoring

**What it does:** Add a `AgentOS.Contracts.HeartbeatMonitor` GenServer that tracks all running agent processes. Each Agent GenServer sends `{:heartbeat, agent_id}` every N seconds (configurable per contract, default 30s). If no heartbeat is received within 3x the interval, the monitor escalates: first attempts `:resume` from checkpoint, then kills and restarts the agent, then marks the contract as failed.

**Why it matters:** Long-running agents can hang (waiting for an API response, stuck in a loop). Heartbeat monitoring detects this and triggers recovery without operator intervention.

**Dependencies:** 2.2 (Agent GenServer), 2.1 (Checkpoints for resume).

### 2.5 Agent Self-Planning

**What it does:** Before execution begins, the Agent GenServer sends the full `ContractSpec` to the LLM via `AgentScheduler.LLMClient` with a planning prompt: "Given this contract, generate an execution plan as a list of steps." The LLM returns a plan (ordered list of `{step_name, tool_ids, estimated_tokens}`). The agent validates the plan against the contract (are all tools allowed? does estimated token usage fit the budget?). If valid, execution proceeds step-by-step. If invalid, the agent re-plans with feedback.

**Why it matters:** Today agents use hardcoded pipelines (see `AgentSpec.completion.pipeline`). Self-planning lets agents adapt their strategy to the specific contract requirements. A research contract about quantum physics might plan differently than one about economics.

**Dependencies:** Phase 1 (ContractSpec with tool and budget constraints), existing `AgentScheduler.LLMClient`.

### 2.6 Execution Plan Persistence

**What it does:** Store the generated execution plan in the `:agent_checkpoints` Mnesia table alongside the contract. The plan becomes part of the agent's recoverable state. After resume, the agent skips completed steps and continues from the next planned step.

**Why it matters:** Without plan persistence, a resumed agent would need to re-plan, potentially generating a different plan that is inconsistent with already-completed steps.

**Dependencies:** 2.1 (Checkpoints), 2.5 (Self-Planning).

---

## Phase 3: Marketplace and Composition

Goal: Contracts become tradeable units. Agents bid on contracts. Contracts compose into pipelines.

### 3.1 Contract-Market Bridge

**What it does:** Connect `AgentOS.Contracts.ContractSpec` to `PlannerEngine.Market`. When a client posts a demand to the `PlannerEngine.OrderBook`, it includes a `ContractSpec` defining the work. When the market clears and creates a `PlannerEngine.Market` contract, it also instantiates the execution `ContractSpec` and passes it to `AgentRunner`. The `PlannerEngine.Escrow` holds credits based on the `ContractSpec.resource_budget`.

**Why it matters:** Today the marketplace contract (client/operator financial agreement) and the execution contract (what the agent must produce) are completely separate concepts. Bridging them means the financial and execution layers are consistent.

**Dependencies:** Phase 1 (ContractSpec), existing `PlannerEngine.Market`, `PlannerEngine.OrderBook`, `PlannerEngine.Escrow`.

### 3.2 Agent Bidding on Contracts

**What it does:** When a `ContractSpec` is posted to the market, registered agents can submit proposals via `PlannerEngine.OrderBook.submit_proposal/1`. The proposal includes: estimated tokens, estimated time, proposed tool set, agent reputation score (from `PlannerEngine.Reputation`). The `OrderBook` ranks proposals by a weighted score: `0.4 * reputation + 0.3 * price_efficiency + 0.3 * estimated_speed`.

**Why it matters:** Instead of manually assigning agents to contracts, the marketplace auto-matches. The best agent for a research paper contract might differ from the best agent for a code review contract.

**Dependencies:** 3.1 (Contract-Market Bridge), existing `PlannerEngine.OrderBook`, `PlannerEngine.Reputation`.

### 3.3 Dynamic Contract Modification

**What it does:** Add `AgentOS.Contracts.Amendment` — a struct representing a proposed change to a running contract (e.g., increase token budget by 20%, add a new tool, extend timeout). The Agent GenServer can request an amendment via `{:request_amendment, amendment}`. The amendment goes through an approval flow: if the contract's `oversight` is `:autonomous_escalation`, amendments within predefined bounds are auto-approved; if `:supervised`, a human must approve; if `:spot_check`, amendments are logged and randomly audited.

**Why it matters:** Agents sometimes discover mid-execution that the contract constraints are too tight. Rather than failing, they can request more resources. This mirrors real-world contract amendments.

**Dependencies:** Phase 2 (Agent GenServer), Phase 1 (ContractSpec).

### 3.4 Contract Composition (Pipelines)

**What it does:** Add `AgentOS.Contracts.Pipeline` — a struct that chains multiple `ContractSpec`s into a sequential or parallel pipeline. Each stage's output artifacts become the next stage's input. The pipeline has its own aggregate budget (sum of stage budgets, or a shared pool). A `PipelineRunner` GenServer manages the stages, using the same checkpoint and heartbeat infrastructure from Phase 2.

**Why it matters:** Complex work requires multiple agents with different specializations. A "publish research paper" pipeline might be: Stage 1 (research agent writes LaTeX) -> Stage 2 (review agent checks citations) -> Stage 3 (formatting agent compiles PDF and pushes to repo). Each stage has its own contract with its own constraints.

**Dependencies:** Phase 2 (GenServer lifecycle, checkpoints), Phase 1 (ContractSpec).

### 3.5 Contract Templates

**What it does:** Add a `AgentOS.Contracts.TemplateRegistry` ETS table that stores named `ContractSpec` templates. Templates are parameterized: `TemplateRegistry.instantiate("research-paper", %{topic: "quantum computing", org: "AgentHeroWork"})` returns a fully populated `ContractSpec`. Ship built-in templates for: `research-paper`, `code-review`, `data-analysis`, `web-scraping-report`.

**Why it matters:** Users should not have to manually construct a `ContractSpec` every time. Templates encode best-practice configurations for common tasks.

**Dependencies:** Phase 1 (ContractSpec).

### 3.6 Contract Audit Trail

**What it does:** Add a `:contract_events` Mnesia table that logs every contract lifecycle event: created, started, checkpoint, amendment_requested, amendment_approved, budget_warning (80% consumed), budget_exceeded, completed, failed. Each event includes timestamp, agent_id, contract_id, and event-specific data. Expose via `AgentOS.Contracts.AuditTrail.events_for(contract_id)`.

**Why it matters:** For accountability and debugging. When a contract fails or an agent misbehaves, the audit trail shows exactly what happened and when.

**Dependencies:** Phase 2 (Agent GenServer lifecycle events), Phase 1 (ContractSpec).

### 3.7 Cross-Node Contract Distribution

**What it does:** Use Mnesia's built-in distribution to replicate `:agent_checkpoints`, `:contract_events`, and `:contract_specs` tables across BEAM nodes. The `AgentScheduler.Agents.Runtime` `:fly` mode already exists; extend it so that when an agent runs on a remote Fly.io machine, the contract spec and checkpoints are replicated to that node via Mnesia's `add_table_copy/3`.

**Why it matters:** Production deployments run multiple BEAM nodes. Contracts and checkpoints must survive node failures and be accessible from any node.

**Dependencies:** Phase 2 (Checkpoints in Mnesia), existing `AgentScheduler.Agents.Runtime`, existing Mnesia infrastructure.

---

## Module Map

Summary of new and modified modules, by phase:

| Phase | Module | Action |
|-------|--------|--------|
| 1.1 | `AgentOS.Contracts.ContractSpec` | **New** |
| 1.2 | `AgentOS.AgentRunner` | Modify (mint capability tokens from contract) |
| 1.2 | `ToolInterface.Capability` | Modify (batch token creation) |
| 1.3 | `AgentOS.Contracts.BudgetEnforcer` | **New** |
| 1.3 | `ToolInterface.Audit` | Modify (telemetry already exists, no changes needed) |
| 1.4 | `AgentOS.Credentials` | Modify (add scope filtering) |
| 1.5 | `AgentOS.AgentSpec` | Modify (remove `@known_agent_types`) |
| 1.5 | `AgentOS.AgentRunner` | Modify (remove hardcoded `resolve_agent_module` clauses) |
| 1.6 | `AgentOS.Contracts.Contract` | Modify (deprecate behaviour, add spec-based verify) |
| 1.6 | `AgentOS.Contracts.ResearchContract` | Modify (return ContractSpec instead of implementing behaviour) |
| 1.7 | `ToolInterface.Capability` | Modify (signing key from config) |
| 2.1 | `AgentOS.Contracts.Checkpoint` | **New** |
| 2.2 | `AgentOS.AgentRunner` | Rewrite (GenServer with DynamicSupervisor) |
| 2.3 | `AgentOS.Contracts.CronScheduler` | **New** |
| 2.4 | `AgentOS.Contracts.HeartbeatMonitor` | **New** |
| 2.5 | `AgentOS.Contracts.Planner` | **New** |
| 2.6 | `AgentOS.Contracts.Checkpoint` | Modify (store plans) |
| 3.1 | `PlannerEngine.Market` | Modify (accept ContractSpec in demand) |
| 3.2 | `PlannerEngine.OrderBook` | Modify (score proposals against ContractSpec) |
| 3.3 | `AgentOS.Contracts.Amendment` | **New** |
| 3.4 | `AgentOS.Contracts.Pipeline` | **New** |
| 3.4 | `AgentOS.Contracts.PipelineRunner` | **New** |
| 3.5 | `AgentOS.Contracts.TemplateRegistry` | **New** |
| 3.6 | `AgentOS.Contracts.AuditTrail` | **New** |
| 3.7 | `AgentOS.Contracts.Checkpoint` | Modify (Mnesia distribution) |

---

## Data Model: ContractSpec

Reference struct for Phase 1:

```elixir
defmodule AgentOS.Contracts.ContractSpec do
  @type t :: %__MODULE__{
    id: String.t(),
    name: String.t(),
    version: pos_integer(),

    # Artifacts
    required_artifacts: [{atom(), artifact_type(), validator_fn()}],

    # Tool Access
    allowed_tools: [String.t()] | :all,
    denied_tools: [String.t()],

    # Resource Budget
    budget: %{
      max_llm_tokens: pos_integer() | :unlimited,
      max_tool_invocations: pos_integer() | :unlimited,
      max_wall_clock_ms: pos_integer() | :unlimited,
      max_cost_credits: pos_integer() | :unlimited
    },

    # Auth
    credential_scope: [atom()],    # e.g. [:github_token, :openai_api_key]

    # Retry Policy
    max_retries: non_neg_integer(),
    retry_delay_ms: non_neg_integer(),

    # Lifecycle (Phase 2)
    checkpoint_interval_ms: pos_integer() | nil,
    heartbeat_interval_ms: pos_integer() | nil,
    wakeup_schedule: [wakeup_entry()] | nil,

    # Oversight
    oversight: :supervised | :spot_check | :autonomous_escalation,

    # Strategy Hints
    parallel_steps_allowed: boolean(),
    escalation_rules: [escalation_rule()],

    metadata: map()
  }
end
```

---

## Execution Flow (Phase 1 + Phase 2)

```
1. Client submits job with ContractSpec
2. AgentRunner.start_link(spec, contract_spec, job)
   a. Validate contract_spec
   b. Resolve scoped credentials (Credentials.resolve with scope)
   c. Mint capability tokens for allowed_tools
   d. Start BudgetEnforcer for this execution
   e. Freeze ToolInterface.Registry
3. Agent self-plans (Phase 2): LLM generates execution plan from contract
4. Agent executes plan step-by-step:
   a. Each tool call checked against capability tokens
   b. Each tool call logged by Audit, counted by BudgetEnforcer
   c. Checkpoint written after each step (Phase 2)
   d. Heartbeat sent every N seconds (Phase 2)
5. On completion: verify artifacts against contract validators
6. On budget exceeded: graceful shutdown, save checkpoint
7. On crash: supervisor restarts, resume from checkpoint (Phase 2)
```
