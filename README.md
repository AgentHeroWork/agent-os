# The AI Operating System

**A five-part research series formalizing the AI Operating System through category theory, with Erlang/Elixir prototypes.**

> An AI Operating System is not a new kernel — it is a software stack that manages AI agents, models, data, memory, and execution the same way a traditional OS manages processes, memory, files, and hardware.

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
              │   Natural Transformation: F ⇒ G         │
              │   Order Book · Escrow · Decomposition   │
              └───────────────────┬─────────────────────┘
                                  │
              ┌───────────────────┴─────────────────────┐
              │          I. Agent Scheduler              │
              │   Objects in Category A                  │
              │   Supervision · Priority · Streaming     │
              └───────────────────┬─────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
┌───────┴────────┐    ┌──────────┴──────────┐    ┌─────────┴────────┐
│ II. Tools      │    │ III. Memory Layer   │    │  Model Runtime   │
│ Morphisms      │    │ Functors            │    │  (LLM Inference) │
│ Capability     │    │ Mem[S] Typed        │    │  GPU Orchestrate │
│ MCP Protocol   │    │ Versioned · Graph   │    │                  │
└────────────────┘    └─────────────────────┘    └──────────────────┘
```

## Papers

| Part | Title | Abstraction | PDF |
|------|-------|-------------|-----|
| I | Agent Scheduler: Complex Orchestration as Process Management | Agents = Objects | [PDF](papers/pdf/agent-scheduler.pdf) |
| II | Tool Interface Layer: Morphisms, Security, and Capability Abstraction | Tools = Morphisms | [PDF](papers/pdf/tool-interface.pdf) |
| III | Memory Layer: Typed Filesystem for Persistent Agent Cognition | Memory = Functor | [PDF](papers/pdf/memory-layer.pdf) |
| IV | Planner Engine: Order Book Dynamics and Natural Transformation | Planner = Nat. Trans. | [PDF](papers/pdf/planner-engine.pdf) |
| V | Synthesis: The AI Operating System as Categorical Framework | Unified Theory | [PDF](papers/pdf/synthesis.pdf) |

## Categorical Mapping

| Resource | Traditional OS | AI OS | Category Theory |
|----------|---------------|-------|-----------------|
| Compute | CPU processes | Agents | Objects in **A** |
| Operations | System calls | Tools (MCP) | Morphisms |
| State | RAM + filesystem | Typed memory Mem[S] | Functors S → St |
| Coordination | Scheduler | Planner (order book) | Natural transformations |
| Fault tolerance | Process restart | OTP supervision | Limit preservation |

## Why Erlang/Elixir

The BEAM VM was designed as a telecom operating system — its primitives map directly to AI OS requirements:

- **Supervision trees** → Agent fault tolerance ("let it crash")
- **Lightweight processes** → Massive agent concurrency (millions per node)
- **ETS + Mnesia** → Working memory + persistent knowledge
- **Hot code reload** → Zero-downtime agent updates
- **Distribution** → Multi-node agent clustering
- **Message passing** → Inter-agent communication without shared state

## Project Structure

```
agent-os/
├── papers/
│   ├── latex/          # Source .tex files
│   └── pdf/            # Compiled PDFs
├── src/
│   ├── agent_scheduler/  # Part I: OTP-based agent scheduling
│   ├── tool_interface/   # Part II: Capability-based tool security
│   ├── memory_layer/     # Part III: Typed memory with ETS/Mnesia
│   ├── planner_engine/   # Part IV: Order book + orchestration
│   └── agent_os/         # Unified umbrella application
├── reviews/            # Peer review feedback
├── posts/              # Social media posts
├── images/             # Paper cover images
├── docs/               # GitHub Pages site
└── .github/workflows/  # CI/CD
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
