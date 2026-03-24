# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Agent-OS is an AI Operating System built on Erlang/OTP. Agents run in microsandbox microVMs with hardware-level isolation. Contracts (YAML) define what agents produce. The LLM decides which tools to use. ContextFS provides long-term memory.

**Stack:** Elixir 1.17/OTP 27 (server), Node.js 18+ (CLI), microsandbox (microVMs), ContextFS (memory)

## Build & Test Commands

```bash
# Compile (from any src/<app>/ directory)
cd src/agent_os && mix compile --warnings-as-errors

# Run tests per app
cd src/agent_scheduler && mix test       # 71 tests
cd src/agent_os && mix test              # 51 tests
cd src/agent_os_web && mix test          # 8 tests
cd src/memory_layer && mix test          # 7 tests
cd src/planner_engine && mix test        # 8 tests
cd src/tool_interface && mix test        # 7 tests

# CLI tests (Node.js)
node --test cli/test/                    # 34 tests

# Run single test file
cd src/agent_os && mix test test/contracts/loader_test.exs

# Start the server (port 4000)
cd src/agent_os && mix run --no-halt

# Start microsandbox (required for pipeline execution)
msb server start --dev

# Start ContextFS ChromaDB (required for memory search)
contextfs server start chroma
```

## Architecture: Two Execution Paths

### Path 1: Single Agent (POST /api/v1/run)
```
Node CLI → HTTP → RunController.run_single → AgentRunner.run → OpenClaw.run_autonomous
  → LLMClient (plan → research → review) → CompletionHandler (LaTeX → PDF → GitHub)
  → Contract validates artifacts → returns results
```
Runs entirely in the BEAM process. No microVM. Uses `AgentScheduler.LLMClient` directly.

### Path 2: Multi-Agent Pipeline (POST /api/v1/pipeline/run)
```
Node CLI → HTTP → RunController.run_pipeline → Loader.load(YAML) → Pipeline.run
  → For each stage:
    ContextBridge.prepare_context (query ContextFS → render .md files)
    MicroVM.run_agent (boot Alpine microVM, mount /context/ + /shared/output/)
    agent-runtime.sh (LLM plans tools, executes, self-repairs, writes proof + audit)
    ContextBridge.ingest_output (save to ContextFS with contract/stage tags)
  → Verify.check(artifacts, contract.verify) → return results
```
Each stage runs in an isolated microsandbox microVM. The agent-runtime.sh is the universal LLM-driven execution loop — no hardcoded scripts per stage.

## OTP App Dependency Graph

```
agent_os (top-level, starts Audit GenServer)
  ├── agent_os_web (Plug/Cowboy HTTP server, port 4000)
  ├── agent_scheduler (agents, scheduler, evaluator, pipeline, LLM client)
  ├── tool_interface (capability tokens, sandbox, audit, registry)
  ├── memory_layer (Mnesia + ETS, graph, versioning, schemas)
  └── planner_engine (escrow, order book, decomposer)
```

`agent_os_web` does NOT depend on `agent_os` — the dependency is inverted. `RunController` uses `apply/3` with module attributes for runtime dispatch to avoid compile-time circular deps.

## Key Modules

| Module | Path | Role |
|--------|------|------|
| `AgentOS.Pipeline` | `src/agent_os/lib/agent_os/pipeline.ex` | Multi-stage orchestrator — calls MicroVM + ContextBridge per stage |
| `AgentOS.MicroVM` | `src/agent_os/lib/agent_os/micro_vm.ex` | Wraps `msb exe` CLI — mounts /scripts, /context, /shared/output |
| `AgentOS.ContextBridge` | `src/agent_os/lib/agent_os/context_bridge.ex` | Renders ContextFS → .md files before VM, ingests output after |
| `AgentOS.AgentRunner` | `src/agent_os/lib/agent_os/agent_runner.ex` | Single-agent monitor — calls `run_autonomous`, validates contract |
| `AgentOS.Audit` | `src/agent_os/lib/agent_os/audit.ex` | Mnesia-backed audit log, reads _proof.json + _audit.json from VMs |
| `AgentOS.Contracts.ContractSpec` | `src/agent_os/lib/agent_os/contracts/contract_spec.ex` | Data-driven contract struct (from YAML) |
| `AgentOS.Contracts.Loader` | `src/agent_os/lib/agent_os/contracts/loader.ex` | Loads YAML from priv/contracts/, hand-rolled parser |
| `AgentScheduler.Agents.OpenClaw` | `src/agent_scheduler/lib/.../openclaw.ex` | Autonomous research agent — plan → research → review → LaTeX → PDF → GitHub |
| `AgentScheduler.LLMClient` | `src/agent_scheduler/lib/.../llm_client.ex` | HTTP client for OpenAI/Anthropic/Ollama via `:httpc` |
| `AgentScheduler.Agent` | `src/agent_scheduler/lib/.../agent.ex` | GenServer per agent — lifecycle state machine with Task.async dispatch |

## Contract System

Contracts are YAML files in `src/agent_os/priv/contracts/`. Two templates exist: `research-report.yaml` and `market-dashboard.yaml`.

```yaml
name: research-report
stages:
  - name: researcher
    instructions: |
      Research the topic. Write findings.md, prices.json, news.json
    output: [findings.md]
  - name: writer
    instructions: |
      Generate LaTeX paper from findings. Compile PDF.
    input_from: researcher
    output: [paper.tex, README.md]
required_artifacts: [findings_md, paper_tex]
verify:
  - file_exists: findings.md
  - min_bytes:
      file: paper.tex
      size: 500
credentials: [github_token]
memory:
  load_past_runs: 5
  knowledge_base: false
```

The `Loader` uses a hand-rolled YAML parser (no external dep). It handles the subset used by these contracts but breaks on flow sequences `[a, b]` or deeply nested maps.

## Agent Runtime (sandbox/scripts/agent-runtime.sh)

One universal script runs in every microVM. The LLM decides which tools to use — no hardcoded scripts per stage.

Flow: read /context/brief.md → call LLM proxy for plan (JSON array of commands) → execute step by step → self-repair on failure → proof-of-work validation → write _proof.json + _audit.json

The LLM proxy at `localhost:4000/api/v1/vm/llm/chat` is exempt from API key auth (handled by `vm_route?/1` in auth plug).

## Auth

- API: Bearer token via `AGENT_OS_API_KEY` env var. Unset = dev mode (no auth).
- VM routes (`/api/v1/vm/*`): exempt from API key auth — microVMs use JOB_TOKEN.
- GitHub: `gh auth token` injected as `GH_TOKEN` env var into microVMs.
- Vercel: `VERCEL_TOKEN` env var injected into microVMs.
- LLM: `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` — never injected into VMs, proxied through BEAM.

## REST API

```
POST   /api/v1/run              Single agent execution
POST   /api/v1/pipeline/run     Multi-stage pipeline
GET    /api/v1/contracts         List YAML contract templates
POST   /api/v1/agents           Create agent GenServer
GET    /api/v1/agents            List agents
POST   /api/v1/agents/:id/start  Assign job (triggers autonomous execution)
POST   /api/v1/agents/:id/stop   Stop agent
GET    /api/v1/agents/:id/logs   Agent metrics
GET    /api/v1/audit/:id         Pipeline audit trail (Mnesia)
GET    /api/v1/audit/:id/:stage/proof  Stage proof report
POST   /api/v1/vm/llm/chat      LLM proxy for microVMs (auth exempt)
GET    /api/v1/tools             List registered tools
GET    /api/v1/health            Health check
```

## CLI (Node.js, cli/)

```bash
agent-os run openclaw --topic "..."          # single agent via HTTP
agent-os run pipeline --contract <name> --topic "..."  # multi-stage pipeline
agent-os agent create --type openclaw --name "..."
agent-os agent list
agent-os health
```

CLI is a pure HTTP client (Node `fetch`). All execution happens on the Elixir server.

## ContextFS Integration

ContextFS runs on the host only. The orchestrator calls `contextfs memory search/save` via `System.cmd`. No ContextFS inside microVMs.

Memory is scoped by tags: `contract:{name}`, `stage:{stage}`, `agent:{id}`. This prevents cross-contamination between unrelated contract runs.

## microsandbox (microVM)

Each pipeline stage runs in an Alpine microVM via `msb exe`. The MicroVM module mounts three volumes:
- `/scripts` (agent-runtime.sh)
- `/context` (read-only, prepared by ContextBridge)
- `/shared/output` (read-write, agent writes results)

Network: `--scope any` gives VM access to host `localhost:4000` for LLM proxy. Alpine uses `apk add` for tool installation at runtime.

## Linear Integration

Project tracked in Linear: team `agent-os` (AOS), project `Agent-OS`. GitHub sync: `AgentHeroWork/agent-os` (bidirectional). Issues pre-existing before sync setup don't auto-sync — need a state change to trigger.

## Known Architectural Issues

- `RunController` uses `apply/3` with module attributes due to inverted dependency (`agent_os` depends on `agent_os_web`, not reverse). Works at runtime but architecturally fragile.
- `collect_artifacts` in `pipeline.ex` uses `String.to_atom` on filenames — potential atom table leak in long-running pipelines.
- The hand-rolled YAML parser strips blank lines from `|` multi-line blocks.
- `ContextBridge.contextfs_save` passes content as a CLI argument (not stdin) — may fail on large content.
