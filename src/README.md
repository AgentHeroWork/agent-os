# Agent-OS Source Architecture

An AI Operating System built on Erlang/OTP. Agents are managed like OS processes — with lifecycle supervision, typed memory, capability-based tool access, credit-weighted scheduling, and contract-driven autonomous execution.

## How It Works Today

Agents (OpenClaw, NemoClaw) run autonomously through contracts. The OS monitors execution, validates outputs, and handles escalation. Here's what a real run looks like:

```
$ agent-os run openclaw --topic "Quantum chromodynamics at the LHC"

OpenClaw: planning research on 'Quantum chromodynamics at the LHC'
OpenClaw: plan generated (4976 chars)
OpenClaw: generating research paper
OpenClaw: research generated (8617 chars)
OpenClaw: reviewing research
OpenClaw: review complete
Wrote LaTeX to /tmp/agent-os/artifacts/cli_1159/quantum-chromodynamics.tex
Created repo: https://github.com/AgentHeroWork/openclaw-quantum-chromodynamics-research
Pushed artifacts to repo
OK: Pipeline completed successfully!
  .tex: /tmp/agent-os/artifacts/cli_1159/quantum-chromodynamics.tex
  .pdf: /tmp/agent-os/artifacts/cli_1159/quantum-chromodynamics.pdf
  repo: https://github.com/AgentHeroWork/openclaw-quantum-chromodynamics-research
```

The agent owns the entire pipeline. Agent-OS only validates artifacts against the contract and handles escalation if the agent gets stuck.

## Quick Start

### Prerequisites

- Elixir 1.17+ / OTP 27+
- `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` environment variable
- `pdflatex` (MacTeX) or `tectonic` for PDF compilation
- `gh` CLI authenticated with AgentHeroWork org access
- `git` with user.name/user.email configured

### Run an Agent

```bash
cd src/agent_os_cli

# Direct execution (no server needed)
mix run -e 'AgentOS.CLI.main(["run", "openclaw", "--topic", "your research topic"])'
mix run -e 'AgentOS.CLI.main(["run", "nemoclaw", "--topic", "your research topic"])'

# With provider/model options
mix run -e 'AgentOS.CLI.main(["run", "openclaw", "--topic", "topic", "--provider", "anthropic"])'
mix run -e 'AgentOS.CLI.main(["run", "openclaw", "--topic", "topic", "--provider", "ollama", "--model", "llama3"])'
```

### Run the Server

```bash
cd src/agent_os
mix deps.get
mix run --no-halt
# Server starts on http://localhost:4000
```

### Use the API

```bash
# Health check
curl http://localhost:4000/api/v1/health

# Create an agent
curl -X POST http://localhost:4000/api/v1/agents \
  -H "Content-Type: application/json" \
  -d '{"type": "openclaw", "name": "researcher-1"}'

# Start it with a job (triggers autonomous execution)
curl -X POST http://localhost:4000/api/v1/agents/openclaw_researcher-1_42/start \
  -H "Content-Type: application/json" \
  -d '{"job_spec": {"topic": "particle physics"}}'

# List agents
curl http://localhost:4000/api/v1/agents

# List tools
curl http://localhost:4000/api/v1/tools
```

### Docker

```bash
docker-compose up -d
# or
docker build -t agent-os .
docker run -p 4000:4000 -e OPENAI_API_KEY=$OPENAI_API_KEY agent-os
```

## Architecture

```
src/
├── agent_os/              # Core OS — contracts, providers, agent runner
│   ├── agent_runner.ex    # Thin monitor: calls run_autonomous, validates, escalates
│   ├── agent_spec.ex      # Agent specification (type, credentials, resources)
│   ├── contracts/         # What agents must produce (not how)
│   │   ├── contract.ex    # Behaviour: required_artifacts, verify, max_retries
│   │   └── research_contract.ex  # Requires: .tex, .pdf, repo_url
│   ├── providers/         # Where agents run
│   │   ├── local.ex       # GenServer on local BEAM node
│   │   ├── fly.ex         # Fly.io Machines API
│   │   └── resolver.ex    # Routes :local/:fly to provider module
│   └── credentials.ex     # Resolves API keys from env/config/gh
│
├── agent_scheduler/       # Process management (the "kernel")
│   ├── agent.ex           # GenServer per agent — lifecycle state machine
│   ├── supervisor.ex      # DynamicSupervisor — fault isolation
│   ├── scheduler.ex       # CFS-style credit-weighted fair scheduling
│   ├── pipeline.ex        # Pub/sub event streaming between agents
│   ├── evaluator.ex       # 6-dimensional quality scoring
│   └── agents/
│       ├── agent_type.ex  # Behaviour: profile, run_autonomous, tool_requirements
│       ├── registry.ex    # GenServer mapping type atoms to modules
│       ├── openclaw.ex    # Full-capability autonomous research agent
│       ├── nemoclaw.ex    # Privacy-guarded agent with NeMo Guardrails
│       ├── completion_handler.ex  # Toolkit: write_latex, compile_pdf, ensure_repo, push
│       ├── self_repair.ex # LLM-powered LaTeX compilation fix loop
│       ├── llm_client.ex  # HTTP client for OpenAI/Anthropic/Ollama
│       └── research_prompts.ex  # Prompt templates + structured output parser
│
├── memory_layer/          # Typed persistent memory
│   ├── memory.ex          # GenServer per memory — create, evolve, merge
│   ├── storage.ex         # ETS (working) + Mnesia (persistent) backends
│   ├── graph.ex           # 9-typed-edge knowledge graph
│   ├── version.ex         # Causal versioning with vector clocks
│   └── schema.ex          # 24 memory types (8 registered: fact, decision, etc.)
│
├── tool_interface/        # Capability-based tool access
│   ├── registry.ex        # 3-tier tool registry (builtin/sandbox/mcp)
│   ├── capability.ex      # HMAC-SHA256 signed capability tokens
│   ├── sandbox.ex         # BEAM process isolation with timeouts
│   └── audit.ex           # Tool usage audit trail
│
├── planner_engine/        # Market-based orchestration
│   ├── order_book.ex      # Proposal/demand matching (price-time priority)
│   ├── escrow.ex          # Credit escrow with Mnesia transactions
│   └── decomposer.ex     # Task decomposition (Kahn's topological sort)
│
├── agent_os_web/          # REST API layer
│   ├── router.ex          # All /api/v1/* routes
│   └── controllers/       # Agent, Job, Tool, Health controllers
│
└── agent_os_cli/          # CLI (escript)
    └── commands/          # run, agent, job, memory, deploy
```

## Agent Execution Model

Agents are autonomous. They own their full pipeline. The OS is a thin monitor.

```
AgentRunner.run(spec, contract, job)
  │
  ├── Call agent_module.run_autonomous(input, context)
  │     │
  │     ├── Agent plans research (LLM)
  │     ├── Agent generates paper (LLM)
  │     ├── Agent reviews paper (LLM)
  │     ├── Agent writes .tex
  │     ├── Agent compiles PDF (self-repair via LLM if errors)
  │     ├── Agent creates GitHub repo
  │     ├── Agent pushes artifacts
  │     └── Returns {:ok, %{artifacts: ...}} or {:escalate, %{reason, message}}
  │
  ├── Validate artifacts against contract.required_artifacts()
  ├── contract.verify(artifacts)
  ├── If {:retry, reason} → call agent again (up to max_retries)
  └── If {:escalate, detail} → handle by reason:
        ├── :compilation_stuck → retry with guidance
        ├── :infrastructure_failure → fail gracefully
        └── :guardrail_violation → fail (security)
```

## Agent Types

| Agent | Oversight | Capabilities | Guardrails |
|-------|-----------|-------------|------------|
| **OpenClaw** | autonomous_escalation | web_search, browser, filesystem, shell, memory | None — full access |
| **NemoClaw** | supervised | web_search, memory | PII detection, domain allowlist, output sanitization |

## Contracts

Contracts define WHAT agents must produce, not HOW.

```elixir
# ResearchContract
required_artifacts() -> [:tex_path, :pdf_path, :repo_url]
verify(artifacts)    -> checks file exists, content > 500 chars
max_retries()        -> 3
```

To create a new contract, implement the `AgentOS.Contracts.Contract` behaviour:

```elixir
defmodule MyContract do
  @behaviour AgentOS.Contracts.Contract

  @impl true
  def required_artifacts, do: [:output_file, :summary]

  @impl true
  def verify(artifacts) do
    if File.exists?(artifacts[:output_file]), do: :ok, else: {:retry, "missing output"}
  end

  @impl true
  def max_retries, do: 2
end
```

## REST API

| Method | Path | Description | Status |
|--------|------|-------------|--------|
| GET | `/api/v1/health` | Health check | Working |
| POST | `/api/v1/agents` | Create agent (`type`, `name`, `oversight`) | Working |
| GET | `/api/v1/agents` | List all agents | Working |
| GET | `/api/v1/agents/:id` | Get agent state | Working |
| POST | `/api/v1/agents/:id/start` | Assign job → triggers autonomous execution | Working |
| POST | `/api/v1/agents/:id/stop` | Stop agent | Working |
| GET | `/api/v1/agents/:id/logs` | Agent metrics/state | Working |
| POST | `/api/v1/jobs` | Submit job to scheduler queue | Working |
| GET | `/api/v1/jobs/:id` | Job status | Stub |
| GET | `/api/v1/tools` | List registered tools | Working |

Auth: Set `AGENT_OS_API_KEY` env on the server. Pass `Authorization: Bearer <key>` header. Unset = dev mode (no auth).

## CLI Reference

```
agent-os run <type> --topic <topic> [--provider openai|anthropic|ollama] [--model <model>]
agent-os agent create --type <type> --name <name> [--oversight <level>]
agent-os agent list
agent-os agent start <id> --job '{"topic": "..."}'
agent-os agent stop <id>
agent-os agent logs <id>
agent-os job submit --task <task> --input '{"key": "value"}'
agent-os deploy docker
agent-os deploy fly [--region <region>]
agent-os health
agent-os version

Global: --host <url> --api-key <key> --target <local|fly> --json
```

## OTP Supervision Tree

```
AgentScheduler.AppSupervisor (rest_for_one)
├── Registry (OTP, unique keys)
├── AgentScheduler.Agents.Registry (maps :openclaw → OpenClaw module)
├── AgentScheduler.Evaluator (6-dim quality scoring)
├── AgentScheduler.Scheduler (CFS credit-weighted queue)
├── AgentScheduler.Pipeline (pub/sub event streaming)
└── AgentScheduler.Supervisor (DynamicSupervisor)
    ├── Agent "openclaw_researcher_1" (GenServer)
    ├── Agent "nemoclaw_privacy_2" (GenServer)
    └── ... (spawned on demand, fault-isolated)
```

## LLM Providers

The system auto-detects providers from environment variables:

| Priority | Env Var | Provider |
|----------|---------|----------|
| 1 | `OPENAI_API_KEY` | OpenAI (gpt-4o default) |
| 2 | `ANTHROPIC_API_KEY` | Anthropic (claude-sonnet-4-20250514 default) |
| 3 | `OLLAMA_HOST` or fallback | Ollama (llama3 default, localhost:11434) |

Override per-run: `--provider anthropic --model claude-opus-4-20250514`

## Deployment

### Local (default)

Agents run as GenServer processes on the local BEAM node. No containers needed. Erlang provides process isolation — one agent crash doesn't affect others.

### Docker

```bash
docker-compose up -d
# Includes tectonic (LaTeX), git, health checks
# Mnesia data persisted in named volume
```

### Fly.io

```bash
fly deploy
# shared-cpu-1x, 512MB, region: iad
# Auto-stop/start, min 1 machine running
# Mnesia volume for persistent memory
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes (or ANTHROPIC) | LLM API key for agent research |
| `ANTHROPIC_API_KEY` | Alternative | Anthropic API key |
| `OLLAMA_HOST` | No | Ollama endpoint (default: localhost:11434) |
| `AGENT_OS_API_KEY` | No | API auth key (unset = dev mode) |
| `AGENT_OS_HOST` | No | CLI target host (default: localhost:4000) |
| `AGENT_OS_TARGET` | No | Provider: `local` or `fly` |
| `FLY_API_TOKEN` | For Fly | Fly.io deploy token |
| `GITHUB_TOKEN` | For repos | GitHub token (or use `gh auth login`) |

## What's Working vs Stub

| Component | Status |
|-----------|--------|
| Agent lifecycle (create/run/stop/crash recovery) | Working |
| Autonomous agent execution (OpenClaw, NemoClaw) | Working |
| Contract validation (ResearchContract) | Working |
| LLM integration (OpenAI, Anthropic, Ollama) | Working |
| LaTeX generation + PDF compilation + self-repair | Working |
| GitHub repo creation + artifact push | Working |
| REST API (agents, jobs, tools, health) | Working |
| CLI (run, agent, job, deploy) | Working |
| Memory layer (ETS + Mnesia, graph, versioning) | Working |
| Credit-weighted scheduling (CFS) | Working |
| Escrow + order book matching | Working |
| Task decomposition (topological sort) | Working |
| Capability tokens (HMAC-SHA256) | Working |
| Process sandbox (BEAM isolation) | Working |
| Docker + Fly.io deployment | Working |
| Tool execute functions (12 tools) | Stub — registry works, execute returns empty |
| Semantic/graph memory backends | Stub — falls through to Mnesia |
| Job status tracking | Stub |
| Memory REST endpoints | Missing controller |
| PlannerEngine.Reputation/Market | Missing modules |

## Tests

```bash
# All apps (from each src/<app>/ directory)
mix test

# CLI tests
node --test cli/test/

# Current: 159 Elixir tests + 30 CLI tests = 189 total, 0 failures
```
