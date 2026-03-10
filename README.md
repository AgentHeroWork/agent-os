# The AI Operating System

**A five-part research series on functional design patterns for intelligent agent infrastructure, with Elixir/OTP reference implementations.**

> An AI Operating System manages models, agents, knowledge, and tasks — the same way a traditional OS manages processes, memory, files, and hardware. We design each subsystem using functional programming principles and implement them in Elixir/OTP.

```
Linux OS → manages hardware + programs
AI OS    → manages models + agents + knowledge + tasks
```

## Authors

**Matthew Long**
The YonedaAI Collaboration · YonedaAI Research Collective
Chicago, IL
matthew@yonedaai.com · https://yonedaai.com

## Architecture

```
                         AI Operating System

              ┌─────────────────────────────────────────┐
              │          IV. Planner Engine              │
              │   Market Clearing · Escrow · Reputation  │
              │   Order Book · DAG Decomposition         │
              └───────────────────┬─────────────────────┘
                                  │
              ┌───────────────────┴─────────────────────┐
              │          I. Agent Scheduler              │
              │   GenServer Lifecycle · Pipeline |>      │
              │   Supervision · Priority · Streaming     │
              └───────────────────┬─────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
┌───────┴────────┐    ┌──────────┴──────────┐    ┌─────────┴────────┐
│ II. Tools      │    │ III. Memory Layer   │    │  Model Runtime   │
│ 3-Tier Registry│    │ Typed Schemas       │    │  (LLM Inference) │
│ Capabilities   │    │ ETS · Mnesia · Graph│    │  GPU Orchestrate │
│ MCP Protocol   │    │ Versioned · 24 Types│    │                  │
└────────────────┘    └─────────────────────┘    └──────────────────┘
```

## Papers

| Part | Title | Design Focus | Read | PDF |
|------|-------|-------------|------|-----|
| I | Agent Scheduler: Composable Orchestration as Process Management | GenServer lifecycle, pipelines, supervision | [HTML](https://agentherowork.github.io/agent-os/papers/agent-scheduler.html) | [PDF](papers/latex/agent-scheduler.pdf) |
| II | Tool Interface Layer: Capability Security and Composable Invocation | 3-tier registry, HMAC tokens, sandboxing | [HTML](https://agentherowork.github.io/agent-os/papers/tool-interface.html) | [PDF](papers/latex/tool-interface.pdf) |
| III | Memory Layer: Typed Filesystem for Persistent Agent Cognition | ETS/Mnesia storage, versioning, graph | [HTML](https://agentherowork.github.io/agent-os/papers/memory-layer.html) | [PDF](papers/latex/memory-layer.pdf) |
| IV | Planner Engine: Market Clearing and Order Book Dynamics | Escrow, reputation, task decomposition | [HTML](https://agentherowork.github.io/agent-os/papers/planner-engine.html) | [PDF](papers/latex/planner-engine.pdf) |
| V | Synthesis: Composing Four Subsystems into an AI OS | Umbrella app, pairwise composition, lifecycle | [HTML](https://agentherowork.github.io/agent-os/papers/synthesis.html) | [PDF](papers/latex/synthesis.pdf) |

## Design Mapping

| Resource | Traditional OS | AI OS | Elixir/OTP Pattern |
|----------|---------------|-------|--------------------|
| Compute | CPU processes | Agents | GenServer + DynamicSupervisor |
| Operations | System calls | Tools (MCP, sandboxed) | Higher-order functions + closures |
| State | RAM + filesystem | Typed memory Mem[S] | ETS (working) + Mnesia (persistent) |
| Coordination | Scheduler | Planner (order book) | GenServer state + Mnesia transactions |
| Composition | Pipes / IPC | Agent pipeline bus | Pipe operator `|>` + message passing |
| Fault tolerance | Process restart | OTP supervision | `one_for_one` / `rest_for_one` strategies |

## Why Elixir/OTP

The BEAM VM was designed as a telecom operating system — its primitives map directly to AI OS requirements:

- **Supervision trees** → Agent fault tolerance ("let it crash")
- **Lightweight processes** → Massive agent concurrency (millions per node)
- **ETS + Mnesia** → Working memory + persistent knowledge
- **Pattern matching** → Type-safe message dispatch and state transitions
- **Pipe operator** → Composable execution pipelines
- **Hot code reload** → Zero-downtime agent updates
- **Distribution** → Multi-node agent clustering
- **Message passing** → Inter-agent communication without shared state

## Quick Start

```bash
cd src/agent_os
mix deps.get
mix compile
iex -S mix
```

```elixir
# Start the AI Operating System
AgentOS.start()

# Check system status
AgentOS.status()
```

## Project Structure

```
agent-os/
├── papers/
│   └── latex/            # Source .tex + compiled PDFs
├── src/
│   ├── agent_scheduler/  # Part I: GenServer lifecycle + pipeline composition
│   ├── tool_interface/   # Part II: 3-tier registry + capability tokens
│   ├── memory_layer/     # Part III: Typed memory with ETS/Mnesia
│   ├── planner_engine/   # Part IV: Order book + escrow + reputation
│   └── agent_os/         # Unified umbrella application
├── scripts/              # LaTeX→HTML conversion tools
├── reviews/              # Gemini peer review feedback
├── docs/                 # GitHub Pages site
│   ├── index.html        # Landing page
│   ├── og-image.png      # Open Graph social image
│   └── papers/           # Readable HTML versions
└── .github/workflows/    # GitHub Pages deployment
```

## Built on Production Systems

This research is grounded in real, deployed systems:

- **[Agent-Hero](https://github.com/AgentHeroWork/agent-hero)** — AI agent marketplace with bidding, escrow, and multi-provider execution
- **[Agent Testing Framework](https://github.com/AgentHeroWork/agent-testing-framework)** — 5-phase streaming pipeline for automated web testing
- **[ContextFS](https://github.com/contextfs/contextfs)** — Typed memory filesystem with versioning, graph lineage, and MCP integration

## Website

[https://agentherowork.github.io/agent-os/](https://agentherowork.github.io/agent-os/)

## License

MIT
