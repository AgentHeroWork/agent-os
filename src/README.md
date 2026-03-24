# Agent-OS

An AI Operating System built on Erlang/OTP + Phoenix. Agents run in microsandbox microVMs with hardware-level isolation. Contracts (YAML) define what agents produce. The LLM decides which tools to use. ContextFS provides long-term memory.

## Quick Start

### Prerequisites

- Elixir 1.17+ / OTP 27+
- Node.js 18+ (CLI)
- `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` env var
- `gh` CLI authenticated (for GitHub operations)
- `pdflatex` or `tectonic` (for PDF compilation)
- `msb` (microsandbox) for pipeline execution: `curl -sSL https://get.microsandbox.dev | sh`

### Start the Server

```bash
cd src/agent_os_web
mix deps.get
mix run --no-halt
# Server starts on http://localhost:4000
```

**Important:** Start from `src/agent_os_web/`, not `src/agent_os/`. The web app brings in all dependencies.

### Start the Web Dashboard

```bash
cd web
npm install
npm run dev
# Dashboard at http://localhost:3000
```

### Verify

```bash
curl http://localhost:4000/api/v1/health
# {"status":"ok","version":"0.1.0","uptime_ms":...}
```

## CLI Reference (Verified Working)

The CLI is a Node.js HTTP client at `cli/`. All commands talk to the server at localhost:4000.

### Working Commands

```bash
# Health & version
agent-os health                                    # GET /api/v1/health
agent-os version                                   # reads package.json

# Auth (stores in ~/.agent-os/config.json)
agent-os login --api-key <key>                     # saves API key locally
agent-os logout                                    # clears saved key

# Single agent run (requires: LLM key, gh, pdflatex)
agent-os run openclaw --topic "your topic"         # POST /api/v1/run
agent-os run nemoclaw --topic "your topic"         # POST /api/v1/run

# Multi-agent pipeline (requires: msb server, LLM key)
agent-os run pipeline --contract research-report --topic "your topic"
agent-os run pipeline --contract market-dashboard --topic "your topic"

# Agent lifecycle
agent-os agent create --type openclaw --name my-agent
agent-os agent list
agent-os agent start <id> --job '{"topic":"test"}'
agent-os agent stop <id>
agent-os agent logs <id>                           # returns state snapshot

# Contracts
agent-os contracts list                            # GET /api/v1/contracts

# Audit
agent-os audit <pipeline-id>                       # GET /api/v1/audit/:id

# Job submission
agent-os job submit --task test --input '{"x":1}'  # POST /api/v1/jobs

# Deploy
agent-os deploy docker                             # builds + docker compose up
agent-os deploy fly --region iad                   # fly deploy
```

### Known Limitations

- `agent-os run openclaw` requires `OPENAI_API_KEY` + `gh` auth + `pdflatex` on the host
- `agent-os run pipeline` requires `msb server start --dev` running
- `agent-os agent logs --follow` flag is accepted but does not stream (single fetch)
- `agent-os job status <id>` returns 404 (JobTracker not wired to submission path)
- Pipeline runs block the HTTP connection with no streaming — CLI shows dots until completion

## Two Execution Paths

### Path 1: Single Agent (`POST /api/v1/run`)

Runs entirely in the BEAM process. No microVM. Agent calls LLM directly.

```
CLI → HTTP → RunController → AgentRunner → OpenClaw.run_autonomous
  → LLMClient (plan → research → review)
  → CompletionHandler (LaTeX → PDF → GitHub)
  → Contract validates artifacts
```

### Path 2: Multi-Agent Pipeline (`POST /api/v1/pipeline/run`)

Each stage runs in an isolated microsandbox microVM. LLM decides which tools to use.

```
CLI → HTTP → RunController → Loader.load(YAML) → Pipeline.run
  → For each stage:
    ContextBridge.prepare_context (ContextFS → .md files)
    MicroVM.run_agent (Alpine microVM, mounts /context/ + /shared/output/)
    agent-runtime.sh (LLM plans tools → executes → self-repairs → proof-of-work)
    ContextBridge.ingest_output (saves to ContextFS with contract/stage tags)
  → Verify.check(artifacts) → return results
```

## The Harness

The harness is everything between the user's intent and the agent's output. Agent-OS provides 6 layers:

| Layer | What It Does | Configurable? |
|-------|-------------|---------------|
| **System Prompts** | Shape agent persona and output format | No — hardcoded in research_prompts.ex and agent-runtime.sh |
| **Tool Selection** | BEAM path: fixed pipeline. MicroVM path: LLM chooses tools dynamically | MicroVM: yes (LLM decides). BEAM: no |
| **Self-Repair** | LaTeX: 3 LLM fix attempts + aggressive sanitize. MicroVM: 1 fix per failed step | Max attempts hardcoded |
| **Proof-of-Work** | Per-file validation: JSON validity, HTML structure, MD size, URL reachability | Auto in microVM, configurable via contract verify rules |
| **Context Injection** | ContextFS queries rendered as .md files in /context/ | Scoped by contract tags. load_past_runs configurable |
| **Escalation** | compilation_stuck → retry. infrastructure_failure → fail. guardrail_violation → fail | Escalation types hardcoded |

### What's Configurable via Environment

| Variable | Effect |
|----------|--------|
| `OPENAI_API_KEY` | Uses OpenAI (gpt-4o default) |
| `ANTHROPIC_API_KEY` | Uses Anthropic (claude-sonnet-4 default) |
| `OLLAMA_HOST` | Uses local Ollama (llama3 default) |
| `AGENT_OS_API_KEY` | Enables bearer token auth (unset = dev mode) |
| `AGENT_OS_PORT` | Server port (default 4000) |
| `VERCEL_TOKEN` | Injected into microVMs for deployment |
| `GH_TOKEN` / `gh auth` | Injected into microVMs for GitHub operations |

### What's Configurable via CLI Flags

```bash
agent-os run openclaw --topic "..." --model claude-opus-4-5 --provider anthropic
```

`--model` and `--provider` work for single-agent runs only. Pipeline runs use the env var provider but hardcode `gpt-4o` as the model name in agent-runtime.sh.

### What Requires Code Changes

- Adding new agent types (need Elixir module + RunController whitelist update)
- Changing system prompts (hardcoded in research_prompts.ex)
- Changing the GitHub org for repos (hardcoded `"AgentHeroWork"` in completion_handler.ex)
- Adding custom verification rules beyond file_exists/min_bytes/key_present
- Changing NemoClaw guardrail lists (PII keywords, approved domains)

## Creating Custom Contracts

Drop a YAML file in `src/agent_os/priv/contracts/`. It's immediately available via `agent-os contracts list` and `agent-os run pipeline --contract <name>`.

```yaml
name: code-review
description: Multi-agent code review pipeline
stages:
  - name: analyzer
    instructions: |
      Analyze the codebase for bugs, security issues, and style problems.
      Write findings to /shared/output/analysis.md
    output:
      - analysis.md
  - name: reviewer
    instructions: |
      Read /context/analysis.md. Write a final review report with severity ratings.
      Write to /shared/output/review.md
    input_from: analyzer
    output:
      - review.md
required_artifacts:
  - analysis_md
  - review_md
verify:
  - file_exists: analysis.md
  - min_bytes:
      file: review.md
      size: 200
credentials:
  - github_token
memory:
  load_past_runs: 3
  knowledge_base: false
max_retries: 1
```

Each stage runs in a separate microVM. The agent-runtime.sh reads `/context/brief.md` (your instructions), asks the LLM to plan shell commands, executes them, validates output, and writes `_proof.json` + `_audit.json`.

## Web Dashboard

The Next.js dashboard at `web/` connects to localhost:4000 and provides:

| Page | What It Shows |
|------|--------------|
| **Dashboard** | Server health, agent count, recent runs |
| **Agents** | Table of agents with status, type, oversight (auto-refreshes) |
| **Pipelines** | Contract selector + topic input → run pipeline |
| **Contracts** | List of available contract templates with stages |
| **Audit** | Pipeline audit trail timeline (enter pipeline ID) |
| **Settings** | Server config, registered tools |

**Known issue:** Contracts page expects object data but API returns strings. Contract details won't display until the API or page is fixed.

## REST API

```
GET    /api/v1/health                         Health check
POST   /api/v1/run                            Single agent execution
POST   /api/v1/pipeline/run                   Multi-stage pipeline
GET    /api/v1/contracts                      List contract templates
POST   /api/v1/agents                         Create agent
GET    /api/v1/agents                         List agents (paginated: ?limit=&offset=)
GET    /api/v1/agents/:id                     Agent detail
POST   /api/v1/agents/:id/start              Assign job → triggers execution
POST   /api/v1/agents/:id/stop               Stop agent
GET    /api/v1/agents/:id/logs               Agent state snapshot
POST   /api/v1/jobs                           Submit job to scheduler
GET    /api/v1/jobs/:id                       Job status (currently broken)
GET    /api/v1/tools                          List registered tools
GET    /api/v1/audit/:pipeline_id             Pipeline audit trail
GET    /api/v1/audit/:pipeline_id/:stage/proof Stage proof report
GET    /api/v1/events/:run_id                 SSE pipeline events (real-time)
POST   /api/v1/vm/llm/chat                   LLM proxy for microVMs (no auth)
```

Auth: Bearer token via `AGENT_OS_API_KEY`. Unset = dev mode. VM routes (`/api/v1/vm/*`) exempt.

## Architecture

```
src/
├── agent_os/              # Core: pipeline, agents, contracts, memory, audit
│   ├── agents/            # OpenClaw, NemoClaw, CompletionHandler, SelfRepair
│   ├── contracts/         # ContractSpec, Loader (yaml_elixir), Verify
│   ├── providers/         # Local, Fly.io deployment
│   ├── pipeline.ex        # Multi-stage orchestrator (MicroVM + ContextBridge)
│   ├── agent_runner.ex    # Single-agent monitor
│   ├── micro_vm.ex        # microsandbox CLI wrapper
│   ├── context_bridge.ex  # ContextFS ↔ filesystem translation
│   ├── llm_client.ex      # OpenAI/Anthropic/Ollama HTTP client
│   └── audit.ex           # Mnesia audit log
│
├── agent_os_web/          # Phoenix API (port 4000)
│   ├── router.ex          # Phoenix.Router with :api and :vm pipelines
│   ├── endpoint.ex        # Phoenix.Endpoint with CORS
│   └── controllers/       # 8 controllers + SSE EventsController
│
├── agent_scheduler/       # Process management
│   ├── agent.ex           # GenServer per agent (lifecycle state machine)
│   ├── supervisor.ex      # DynamicSupervisor
│   ├── scheduler.ex       # CFS-style credit-weighted queue with dispatch loop
│   └── evaluator.ex       # 6-dimensional quality scoring
│
├── memory_layer/          # Typed persistent memory (ETS + Mnesia)
├── planner_engine/        # OrderBook, Escrow, Market, Decomposer, Reputation
├── tool_interface/        # Registry, Capability tokens, Sandbox
│
web/                       # Next.js 15 operator dashboard
cli/                       # Node.js CLI (HTTP client)
sandbox/scripts/           # agent-runtime.sh (universal LLM-driven VM runtime)
```

## Tests

```bash
# Elixir (from each src/<app>/ directory)
cd src/agent_scheduler && mix test    # 29 tests
cd src/agent_os && mix test           # 90 tests
cd src/agent_os_web && mix test       # 8 tests
cd src/memory_layer && mix test       # 7 tests
cd src/planner_engine && mix test     # 8 tests
cd src/tool_interface && mix test     # 7 tests

# CLI
node --test cli/test/                 # 47 tests

# Total: 196 tests, 0 failures
```
