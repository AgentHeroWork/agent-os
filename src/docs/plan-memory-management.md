# Feature Plan: Memory Management

## The Core Principle

**Agents won't use memory unless you tell them they have it.**

An LLM-based agent is a stateless function call. It has no inherent memory. If the system prompt doesn't say "you have memory, here's what you remember, here's how to save things" — the agent will be forgetful every single run. Memory is not optional infrastructure; it's an explicit capability that must be injected into the agent's context and prompt.

This means memory management has two sides:
1. **OS-managed (automatic)** — the agent never asks; the OS records, checkpoints, loads, and GCs
2. **Agent-managed (explicit API)** — the agent decides what to remember, what to recall, what to share

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Agent Prompt / Context                     │
│                                                               │
│  "You are OpenClaw. You have persistent memory.               │
│   Here are your last 3 runs on similar topics: [...]          │
│   You saved these findings last time: [...]                   │
│   Use memory.save() to remember important findings.           │
│   Use memory.search() to look up past knowledge."             │
│                                                               │
│  context.past_runs = [%AgentRunData{...}, ...]    ← OS auto  │
│  context.memories  = [%FactData{...}, ...]        ← OS auto  │
│  context.memory    = %AgentMemory{...}            ← API handle│
└─────────────────────────────────────────────────────────────┘
        │                           │
        ▼                           ▼
┌───────────────┐         ┌──────────────────┐
│  OS Automatic │         │  Agent Explicit   │
│               │         │                   │
│ • Record run  │         │ • memory.save()   │
│ • Checkpoint  │         │ • memory.recall() │
│ • Load past   │         │ • memory.search() │
│   runs into   │         │ • memory.share()  │
│   context     │         │                   │
│ • GC / decay  │         │ Agent decides     │
│ • Crash resume│         │ what matters      │
└───────┬───────┘         └────────┬──────────┘
        │                          │
        ▼                          ▼
┌─────────────────────────────────────────────┐
│              Storage Layer                   │
│                                              │
│  Mnesia ─── working memory, checkpoints,     │
│             memos, run history               │
│             (fast, in-BEAM, transactional)    │
│                                              │
│  ContextFS ── long-term knowledge,           │
│               cross-session recall,           │
│               semantic search                 │
│               (survives everything)           │
│                                              │
│  Git + .md ── artifact memory                │
│               (OpenClaw already does this)    │
│               README = summary, repo = memory │
└─────────────────────────────────────────────┘
```

## What Is Long-Term Memory?

Long-term memory is anything an agent needs to recall **across runs** — not within a single pipeline execution, but days, weeks, or months later. Here's what agents actually store:

| Memory Type | Example | When Created | When Recalled | Lifetime |
|---|---|---|---|---|
| **Run history** | "I wrote a paper on QCD, took 45s, repo created" | After every run (OS auto) | Next run on similar topic | Months |
| **Learned fix** | "Underscore in LaTeX title breaks pdflatex — escape first" | After self-repair fixes a bug | Next time compilation fails | Forever |
| **Research finding** | "H→bb branching ratio is 58%, cite Aad et al. 2012" | Agent saves during research | Future paper on Higgs | Weeks–months |
| **Failed approach** | "Ollama llama3 can't produce structured TITLE:/ABSTRACT: output" | After pipeline failure | Next run with same provider | Months |
| **Domain knowledge** | "ATLAS detector has 4 subsystems: inner tracker, calorimeters, muon spectrometer, magnets" | Accumulated from multiple runs | Any CERN-related research | Forever |
| **Agent preference** | "3-section papers compile more reliably than 7-section" | Observed pattern across runs | Planning phase | Forever |
| **Collaboration note** | "NemoClaw found PII in dataset X — avoid that source" | Shared from NemoClaw | OpenClaw researching same dataset | Weeks |

What's **NOT** long-term memory:

| Memory | Example | Lifetime | Storage |
|---|---|---|---|
| Current step result | "Plan text: 4976 chars" | This run only | Mnesia memo_store |
| Checkpoint | "Completed steps 1-4, starting step 5" | Until run completes | Mnesia |
| LLM response cache | "GPT-4o returned this for this exact prompt" | Hours | Mnesia (with TTL) |

The distinction: **working memory is disposable after the run completes. Long-term memory persists across runs and gets better over time.**

## Three Time Horizons, Three Storage Layers

```
                    ┌─────────────────────┐
   This execution   │      Mnesia         │  Sub-ms reads
   (seconds–mins)   │  memo_store         │  In-BEAM, transactional
                    │  checkpoints        │  Lost if Mnesia wiped
                    │  LLM response cache │
                    └────────┬────────────┘
                             │ AgentRunData written here too
                             │ (fast query for "last 5 runs")
                    ┌────────┴────────────┐
   Across runs      │  ContextFS (CLI)    │  ~100ms reads
   (days–months)    │  facts              │  SQLite + ChromaDB
                    │  decisions          │  Semantic search
                    │  procedures         │  Survives everything
                    │  episodic summaries │  Syncs to cloud
                    │  domain knowledge   │
                    └────────┬────────────┘
                             │ Repos are memory too
                    ┌────────┴────────────┐
   Forever          │    Git + GitHub     │  Permanent
   (artifacts)      │  .tex, .pdf         │  GitHub search
                    │  README.md          │  Already working
                    └─────────────────────┘
```

These aren't competing — they serve **different time horizons** and the StorageRouter handles write-through and read-fallback between them.

## How They Work Together: Concrete Example

Here's what happens on a second run of OpenClaw, after it already completed a QCD paper:

```
RUN #2: agent-os run openclaw --topic "Higgs boson mass measurements"

═══ STEP 1: AgentRunner.build_context() ═══════════════════════════

  Mnesia query (sub-ms):
    → Load last 5 AgentRunData records
    → "Run #1: QCD paper, 45s, success, repo created"
    → "Run #0: failed — Ollama couldn't follow structured format"

  ContextFS CLI (~100ms each):
    $ contextfs search "Higgs boson" --type fact --limit 10 --json
    → "H→bb branching ratio is 58%" (saved by agent in run #1)
    → "ATLAS Run 2 luminosity: 139 fb⁻¹" (saved in run #1)

    $ contextfs search "Higgs boson" --type decision --limit 5 --json
    → "Use 3-section structure for shorter topics" (learned pattern)

    $ contextfs search "compilation" --type procedural --limit 5 --json
    → "Always run aggressive_sanitize before first compile" (learned fix)

  Build memory_prompt for LLM:
    "You have persistent memory across sessions.

     PAST RUNS (last 3 on similar topics):
     - 2026-03-17: 'QCD at the LHC' → completed, 45s, repo created
     - 2026-03-15: 'Higgs decay' → failed, Ollama format issue

     KNOWN FACTS (relevant to current topic):
     - [fact] H→bb branching ratio is 58%, cite Aad et al. 2012
     - [fact] ATLAS Run 2 luminosity: 139 fb⁻¹

     PROCEDURES (learned from past runs):
     - [procedural] Always run aggressive_sanitize before first compile

     MEMORY API — call during execution:
     - context.memory.save(key, value, :fact | :decision | :procedural)
     - context.memory.search(query)
     - context.memory.recall(key)"

═══ STEP 2: OpenClaw.run_autonomous(input, context) ═══════════════

  Agent reads context.memory_prompt → includes in LLM system prompt
  LLM plans research → uses known facts, skips redundant searches
  LLM generates paper → cites H→bb ratio from memory (not hallucinated)

  Agent saves new finding:
    context.memory.save("higgs_mass_2024", "125.25 ± 0.17 GeV", :fact)

    StorageRouter handles write-through:
      1. Mnesia.save(memory)          # sub-ms, available this session
      2. System.cmd("contextfs", [    # durable, searchable for future
           "save", "--type", "fact",
           "--tags", "agent:openclaw,topic:higgs",
           "--project", "agent-os"
         ], input: "125.25 ± 0.17 GeV, Aad et al., ATLAS+CMS 2024")

  compile_pdf → uses learned procedure (aggressive_sanitize first)
    → Compilation succeeds on first try (learned from past failure!)

  Pipeline completes with artifacts

═══ STEP 3: AgentRunner post-run (OS automatic) ═══════════════════

  Mnesia: save AgentRunData
    %{status: :completed, duration_ms: 38_000, topic: "Higgs boson mass",
      artifacts: %{tex_path: "...", pdf_path: "...", repo_url: "..."}}

  ContextFS CLI: save episodic summary
    $ contextfs save --type episodic --tags "agent:openclaw,run:2"
      input: "Completed Higgs boson mass paper in 38s. Used known H→bb
              ratio from memory. Compilation succeeded first try using
              aggressive_sanitize procedure. New finding: mass = 125.25 GeV."

  ContextFS CLI: evolve domain knowledge
    $ contextfs evolve <higgs_mass_id> --summary "Updated with 2024 combined measurement"
      input: "125.25 ± 0.17 GeV (ATLAS+CMS combined, 2024)"
```

And the read path when an agent searches:

```elixir
# Agent calls:
context.memory.search("Higgs boson measurements")

# StorageRouter does:
1. Mnesia.search("Higgs boson measurements")
   → Returns recent saves from this session (sub-ms)
   → Maybe 1-2 results

2. If fewer than `limit` results:
   System.cmd("contextfs", ["search", "Higgs boson measurements",
     "--limit", "10", "--type", "fact", "--json"])
   → Returns semantically relevant results from all past sessions
   → Ranked by hybrid BM25 + cosine similarity

3. Deduplicate by content_hash
4. Merge results (Mnesia results first, ContextFS fills gaps)
5. Return to agent
```

## Who Owns What

| Concern | Owner | Why |
|---|---|---|
| Record every run | OS (automatic) | Infrastructure — agent shouldn't have to ask |
| Checkpoint mid-execution | OS (automatic) | Crash recovery is infrastructure |
| Load past runs into context | OS (automatic) | Agent needs this in its prompt to be informed |
| Inject memory instructions into agent prompt | OS (automatic) | Agent won't use memory unless told |
| GC / TTL / decay | OS (automatic) | Lifecycle management is infrastructure |
| Save a finding for later | Agent (explicit) | Only the agent knows what's worth remembering |
| Search past knowledge | Agent (explicit) | Agent decides when it needs context |
| Share with another agent | Agent (explicit) | Agent decides what to share |
| Choose storage backend | Contract (declared) | Contract spec says what memory the agent needs |

## Current State

### What Exists

- `MemoryLayer.Memory` — GenServer per instance, ETS + Mnesia, create/evolve/merge
- `MemoryLayer.Storage` — multi-backend router (semantic/graph backends are stubs)
- `MemoryLayer.Graph` — 9-typed edges in Mnesia
- `MemoryLayer.Version` — vector clocks with 4 change reasons
- `MemoryLayer.Schema` — 24 types defined, 8 registered, `AgentRunData` exists but unused
- `ContextFS` — external tool, already available via MCP, has search/save/recall

### What's Broken

1. **Zero integration** — `MemoryLayer` and agent runtime have no connection
2. **Agents don't know they have memory** — no memory instructions in LLM prompts
3. **memo_store lost on crash** — in-process map, not persisted
4. **No execution recording** — `AgentRunData` schema exists, nothing writes to it
5. **No past context loading** — agents start every run from zero
6. **Vector clocks use `node()`** — breaks on restart
7. **16 of 24 schema types unregistered** — missing structs
8. **No GC** — Mnesia grows unbounded
9. **Flat namespace** — all agents share one memory space

---

## Phase 1: Wire Memory to Agents (Tell Them They Have It)

Goal: Agents receive memory context in their prompt, OS auto-records runs, checkpoints persist to Mnesia.

### Feature 1.1: Memory-Aware Agent Prompts

**What it does.** Modifies `AgentScheduler.ResearchPrompts` (and any future prompt modules) to include a memory section in the system prompt. When `AgentOS.AgentRunner.build_context/2` prepares context, it queries past runs and saved memories, then formats them as a prompt section:

```
You have persistent memory across sessions.

PAST RUNS (last 3 on similar topics):
- 2026-03-17: "Quantum Chromodynamics at the LHC" → completed, 8617 chars, repo created
- 2026-03-15: "Higgs Boson Decay Channels" → completed, 7200 chars
  You saved: "Key finding: H→bb channel has 58% branching ratio"

SAVED KNOWLEDGE (relevant to current topic):
- [fact] "QCD coupling constant runs logarithmically with energy scale"
- [decision] "Use 2-loop perturbative expansion for precision > 1%"

MEMORY API (call these during execution):
- context.memory.save(key, value, :fact | :decision | :procedural)
- context.memory.search(query_string)
- context.memory.recall(key)
- context.memory.share(target_agent_id, key)
```

**Why it matters.** This is THE critical feature. Without this, agents are stateless. With this, every LLM call knows what the agent has done before, what it learned, and how to save new knowledge. The agent literally cannot use memory unless its prompt says so.

**Dependencies.** Feature 1.2 (memory client to query past data).

### Feature 1.2: Agent Memory Client

**What it does.** New module `MemoryLayer.AgentMemory` provides the API agents call during execution:

```elixir
defmodule MemoryLayer.AgentMemory do
  def save(agent_id, key, value, type)     # persist a memory
  def recall(agent_id, key)                 # get by key
  def search(agent_id, query, opts \\ [])   # search by content
  def share(agent_id, target_id, key)       # copy to another agent's namespace
  def past_runs(agent_id, opts \\ [])       # query run history
  def list(agent_id, type, opts \\ [])      # list memories by type
end
```

All operations are automatically scoped to the agent's namespace. Wraps `MemoryLayer.Memory`, `MemoryLayer.Storage`, and `MemoryLayer.Graph`.

**Why it matters.** Single entry point with namespace enforcement. Agents call `context.memory.save(...)` — the OS handles where and how it's stored.

**Dependencies.** None — builds on existing `MemoryLayer` APIs.

### Feature 1.3: Inject Memory Handle into Agent Context

**What it does.** Modifies `AgentOS.AgentRunner.build_context/2` to:
1. Query `MemoryLayer.AgentMemory.past_runs(agent_id, limit: 5)` for recent history
2. Query `MemoryLayer.AgentMemory.search(agent_id, topic)` for relevant saved memories
3. Build a `memory_prompt` string with formatted past runs + saved knowledge + API instructions
4. Add `context.memory` handle, `context.past_runs`, `context.memories`, `context.memory_prompt`

Agent modules (OpenClaw, NemoClaw) receive this in `run_autonomous(input, context)` and include `context.memory_prompt` in their LLM system prompts.

**Why it matters.** This is the bridge between the memory system and the agent's LLM calls. The agent's prompt includes memory context, and the agent has an API handle to save/recall during execution.

**Dependencies.** Feature 1.2 (memory client).

### Feature 1.4: Automatic Execution Recording

**What it does.** Wraps `AgentOS.AgentRunner.run/3`:
- On start: creates `AgentRunData` memory (status: `:running`, started_at, task, input)
- On success: evolves to `:completed` with artifacts, duration, model used
- On failure: evolves to `:failed` with error reason
- On escalation: evolves to `:escalated` with detail

Uses existing `MemoryLayer.Schema.AgentRunData` struct — no new schema needed.

**Why it matters.** Every agent run becomes queryable history. Feature 1.1 depends on this — can't show past runs in the prompt if they're not recorded.

**Dependencies.** Feature 1.2 (memory client for writing records).

### Feature 1.5: Persistent Memo Store

**What it does.** Replaces the in-process `memo_store` map in `AgentScheduler.Agent` with Mnesia-backed storage. Completed step results are written to Mnesia. On agent restart, `init/1` loads existing memos, enabling true crash recovery.

**Why it matters.** The entire durable execution model is broken without this. Agent crashes mid-pipeline and restarts from step 1 instead of resuming from the last completed step.

**Dependencies.** Feature 1.2 (memory client).

### Feature 1.6: Persistent Checkpoints

**What it does.** `AgentScheduler.Agent.handle_call(:checkpoint)` writes checkpoint data to Mnesia instead of GenServer state only. On restart, `init/1` checks for existing checkpoint and restores.

**Why it matters.** Checkpoints are currently decorative — only in volatile GenServer state.

**Dependencies.** Feature 1.5 (persistent memo store).

### Feature 1.7: Stable Vector Clock Keys

**What it does.** Changes vector clock key from `node()` to agent ID string. Agent IDs are stable across restarts.

**Why it matters.** `node()` changes on restart, breaking causal ordering.

**Dependencies.** Feature 1.3 (agent ID available in memory context).

---

## Phase 2: Lifecycle, Namespacing, Storage Backends

Goal: Memory has scoped namespaces, TTL-based decay, GC, and agents choose storage backends via contracts.

### Feature 2.1: Memory Namespacing

**What it does.** Adds `namespace` field to memory records. Hierarchy: `agent:{id}` → `contract:{id}` → `shared` → `global`. Secondary Mnesia index on namespace.

**Why it matters.** All agents currently share one flat memory space. Agent A can see Agent B's internals.

**Dependencies.** Feature 1.2 (AgentMemory client sets namespace automatically).

### Feature 2.2: Contract-Declared Memory Requirements

**What it does.** Extends `ContractSpec` (from the agent contracts plan) with memory configuration:

```elixir
%ContractSpec{
  memory: %{
    auto_checkpoint: true,          # OS checkpoints every N steps
    checkpoint_interval_steps: 3,   # checkpoint every 3 steps
    auto_record: true,              # OS records run as AgentRunData
    load_past_runs: 5,              # OS loads last 5 runs into context
    load_relevant_memories: 10,     # OS loads top 10 relevant memories
    agent_memory_access: true,      # Agent gets memory API in context
    storage_backend: :mnesia,       # :mnesia | :contextfs | :both
    storage_budget_mb: 100,         # Max memory per agent
    ttl_days: 30                    # Auto-expire after 30 days
  }
}
```

`AgentRunner` reads this config and adjusts behavior: how many past runs to load, whether to enable checkpoints, which storage backend to use.

**Why it matters.** Different contracts need different memory strategies. A quick 5-minute task doesn't need checkpoints. A 3-day research project needs persistent memory + semantic search.

**Dependencies.** Agent contracts plan Phase 1, Feature 1.3 (memory injection).

### Feature 2.3: ContextFS Integration (via CLI)

**What it does.** Implements `MemoryLayer.Backend.ContextFS` that shells out to the `contextfs` CLI for long-term storage and semantic search. Uses `System.cmd("contextfs", [...])` — same pattern as `gh` and `git` in `CompletionHandler`. No MCP server dependency.

CLI commands mapped to backend operations:

```elixir
# save → contextfs save --type fact --tags "agent:openclaw" --project agent-os
System.cmd("contextfs", ["save", "--type", type, "--tags", tags, "--project", project],
  input: content, stderr_to_stdout: true)

# search → contextfs search "query" --limit 10 --type fact --json
System.cmd("contextfs", ["search", query, "--limit", to_string(limit),
  "--type", type, "--json"], stderr_to_stdout: true)

# recall → contextfs recall <id> --json
System.cmd("contextfs", ["recall", id, "--json"], stderr_to_stdout: true)

# evolve → contextfs evolve <id> --summary "..." --json
System.cmd("contextfs", ["evolve", id, "--summary", summary],
  input: new_content, stderr_to_stdout: true)

# list → contextfs list --limit 20 --type agent_run --json
System.cmd("contextfs", ["list", "--limit", to_string(limit),
  "--type", type, "--json"], stderr_to_stdout: true)
```

All responses parsed as JSON. Errors handled gracefully — if `contextfs` is not installed, backend returns `{:error, :contextfs_not_available}` and the router falls back to Mnesia.

When `storage_backend: :contextfs` or `:both`:
- **Writes** go to Mnesia first (fast, authoritative), then ContextFS (durable, searchable)
- **Semantic search** goes to ContextFS (has embeddings + hybrid BM25/cosine)
- **Recall by ID** checks Mnesia first (sub-ms), falls back to ContextFS
- **Keyword search** uses Mnesia match_spec first, enriches with ContextFS FTS5

ContextFS namespacing maps to agent-os namespacing:
- Agent namespace `agent:{id}` → ContextFS `--tags "agent:{id}"` filter
- Project namespace → ContextFS `--project agent-os`
- Shared namespace → ContextFS `--tags "shared"` with `--cross-repo`

**Why it matters.** ContextFS already has semantic search (ChromaDB/pgvector), typed schemas (22 types matching our 24), graph edges, evolution/lineage, and cross-session persistence. Instead of reimplementing all of that in Erlang, we delegate to ContextFS for what it's good at (long-term semantic recall) and keep Mnesia for what it's good at (fast in-BEAM working memory).

CLI over MCP because:
- No server process to keep running
- Stateless — each call is independent
- Same pattern already working for `gh`, `git`, `pdflatex` in the codebase
- If ContextFS isn't installed, graceful fallback to Mnesia-only
- Can add MCP backend later behind the same `StorageBackend` behaviour if needed

**Dependencies.** `contextfs` CLI installed (`pip install contextfs`). Feature 2.2 (contract declares storage backend).

### Feature 2.4: Complete Schema Registration

**What it does.** Defines struct modules for all 16 unregistered types. Registers all 24 in `Schema.Registry.init/1`.

**Why it matters.** `TaskData`, `StepData` needed for workflow tracking. `SessionData`, `ContextData` needed for working memory. `EmbeddingData` needed for semantic search.

**Dependencies.** None.

### Feature 2.5: Memory TTL and Decay Scheduling

**What it does.** `MemoryLayer.DecayScheduler` GenServer runs on configurable interval. Queries Mnesia for memories past TTL, soft-deletes them. Heuristic TTL by type: `:log` = 7 days, `:step` = 30 days, `:fact` = never.

**Why it matters.** Without decay, Mnesia grows forever.

**Dependencies.** Feature 1.4 (execution recording creates memories that need lifecycle).

### Feature 2.6: Memory Garbage Collection

**What it does.** `MemoryLayer.GC` periodically removes soft-deleted records older than retention period. Respects lineage (memories with active children via graph edges are preserved).

**Why it matters.** Soft deletes are the only deletion mechanism but tombstones are never cleaned.

**Dependencies.** Feature 2.5 (decay creates tombstones for GC to clean).

### Feature 2.7: Per-Agent Memory Budgets

**What it does.** Limits per agent: `max_memories` (count), `max_memory_bytes` (storage). When exceeded, evict oldest low-priority memories first (`:log`, `:step`), then `:episodic`, then `:fact`.

**Why it matters.** One runaway agent shouldn't exhaust memory for the whole system.

**Dependencies.** Feature 2.1 (namespacing — budgets per namespace).

---

## Phase 3: Memory-Informed Intelligence

Goal: Agents learn from experience, share knowledge, and use memory to improve over time.

### Feature 3.1: Memory-Informed Planning

**What it does.** `AgentRunner.build_context/2` queries past runs for the current task type, extracts success/failure patterns, and includes them in the agent's prompt:

```
LESSONS FROM PAST RUNS:
- Run #47 failed at PDF compilation because underscore in title wasn't escaped.
  Fix: always run aggressive_sanitize before first compile attempt.
- Run #45 succeeded in 28s. Strategy: use 3-section structure for topics < 5 words.
```

The agent's LLM uses this to adjust its strategy.

**Why it matters.** Without this, every run starts from zero. With this, agents get better over time.

**Dependencies.** Feature 1.4 (recorded runs to learn from), Feature 1.1 (memory-aware prompts).

### Feature 3.2: Cross-Agent Memory Sharing

**What it does.** `MemoryLayer.AgentMemory.share(from_id, to_id, key)` copies a memory to the target agent's namespace. `MemoryLayer.SharedMemory` module manages the `shared` namespace. Graph edges track provenance (`:derived_from` linking shared memory to source agent).

**Why it matters.** Multi-agent workflows need knowledge transfer. Agent A researches, Agent B synthesizes — B needs A's findings.

**Dependencies.** Feature 2.1 (namespacing), Feature 1.2 (memory client).

### Feature 3.3: Episodic Memory Synthesis

**What it does.** After each run, synthesize an `EpisodicData` memory: what worked, what failed, what to do differently. Links to `AgentRunData` via `:derived_from` edge. Over time, agents accumulate experience.

**Why it matters.** `AgentRunData` is raw execution data. Episodic memories are interpreted experience — lessons, not logs.

**Dependencies.** Feature 1.4 (execution recording), Feature 1.1 (memory-aware prompts to leverage episodes).

### Feature 3.4: Memory-Driven Reputation

**What it does.** `AgentScheduler.Evaluator` persists scores to memory layer. Reputation history becomes queryable and survives restarts.

**Why it matters.** Evaluation scores are currently in volatile GenServer state.

**Dependencies.** Feature 2.4 (complete schema — need `EvaluationData` struct).

---

## Implementation Order

```
Phase 1 (Weeks 1-3) — Make agents remember
  1.1 Memory-aware agent prompts          ← THE critical feature
  1.2 Agent memory client (AgentMemory)
  1.3 Inject memory handle into context
  1.4 Automatic execution recording
  1.5 Persistent memo store (Mnesia)
  1.6 Persistent checkpoints
  1.7 Stable vector clock keys

Phase 2 (Weeks 4-6) — Manage the memory
  2.1 Memory namespacing
  2.2 Contract-declared memory requirements
  2.3 ContextFS integration (long-term backend)
  2.4 Complete schema registration (16 missing types)
  2.5 Memory TTL and decay scheduling
  2.6 Memory garbage collection
  2.7 Per-agent memory budgets

Phase 3 (Weeks 7-10) — Learn from memory
  3.1 Memory-informed planning
  3.2 Cross-agent memory sharing
  3.3 Episodic memory synthesis
  3.4 Memory-driven reputation
```

## Module Map

| New Module | OTP App | Purpose |
|---|---|---|
| `MemoryLayer.StorageBackend` | memory_layer | Behaviour with capability flags (like ContextFS StorageProtocol) |
| `MemoryLayer.Backend.Mnesia` | memory_layer | Fast in-BEAM backend (extract from current Storage) |
| `MemoryLayer.Backend.ContextFS` | memory_layer | Long-term backend via `contextfs` CLI (System.cmd) |
| `MemoryLayer.Backend.Postgres` | memory_layer | Production unified backend (pgvector + tsvector) — future |
| `MemoryLayer.StorageRouter` | memory_layer | Routes ops to backends by capability + contract config |
| `MemoryLayer.AgentMemory` | memory_layer | Agent-scoped memory client (save/recall/search/share) |
| `MemoryLayer.DecayScheduler` | memory_layer | TTL enforcement, periodic decay |
| `MemoryLayer.GC` | memory_layer | Garbage collection of tombstoned records |
| `MemoryLayer.SharedMemory` | memory_layer | Cross-agent memory publishing |

| Modified Module | Change |
|---|---|
| `AgentScheduler.ResearchPrompts` | Add memory section to system prompts |
| `AgentScheduler.Agent` | Persist memo_store to Mnesia, restore on init |
| `AgentOS.AgentRunner` | Record runs, inject memory context, load past runs |
| `AgentScheduler.Agents.OpenClaw` | Include `context.memory_prompt` in LLM calls, use `context.memory.save()` |
| `AgentScheduler.Agents.NemoClaw` | Same as OpenClaw + guardrail memory (remember blocked content) |
| `MemoryLayer.Memory` | Add namespace field, stable vector clock keys |
| `MemoryLayer.Storage` | Add ContextFS backend, namespace filtering |
| `MemoryLayer.Schema` | Define 16 missing structs, register all 24 types |
| `AgentScheduler.Evaluator` | Persist evaluations to memory layer |

## Pluggable Storage Architecture

Storage is a behaviour. Any backend that implements it can plug in. The router picks backends based on what the operation needs.

```
MemoryLayer.StorageBackend (behaviour)
  │
  ├── MemoryLayer.Backend.Mnesia        ← fast working memory, checkpoints, run history
  │     Sub-ms, in-BEAM, transactional, Mnesia tables with secondary indexes
  │     Capabilities: persistent, transactions, batch_operations
  │
  ├── MemoryLayer.Backend.ContextFS     ← long-term knowledge, semantic search
  │     Calls `contextfs` CLI via System.cmd (same pattern as gh/git/pdflatex)
  │     Capabilities: persistent, semantic_search, full_text_search, syncable, graph_traversal
  │
  ├── MemoryLayer.Backend.Postgres      ← production unified (future)
  │     pgvector + tsvector + recursive CTEs for graph
  │     Capabilities: all
  │
  └── MemoryLayer.StorageRouter         ← routes operations to backends by capability
        Write: Mnesia first (authoritative) → ContextFS (durable)
        Semantic search: ContextFS → Postgres
        Recall by ID: Mnesia (fast) → ContextFS (fallback)
        Graph traversal: Mnesia edges → ContextFS links
```

```elixir
defmodule MemoryLayer.StorageBackend do
  @type capabilities :: %{
    semantic_search: boolean(),
    full_text_search: boolean(),
    persistent: boolean(),
    syncable: boolean(),
    graph_traversal: boolean(),
    batch_operations: boolean(),
    transactions: boolean()
  }

  @callback capabilities() :: capabilities()
  @callback save(Memory.t()) :: {:ok, Memory.t()} | {:error, term()}
  @callback recall(String.t()) :: {:ok, Memory.t()} | {:error, :not_found}
  @callback search(String.t(), keyword()) :: {:ok, [SearchResult.t()]}
  @callback delete(String.t()) :: :ok | {:error, term()}
  @callback save_batch([Memory.t()]) :: {:ok, non_neg_integer()}
end
```

The contract declares which backends the agent needs:

```elixir
%ContractSpec{
  memory: %{
    backends: [:mnesia, :contextfs],   # or [:mnesia], or [:mnesia, :postgres]
    search_mode: :hybrid               # :keyword | :semantic | :hybrid
  }
}
```

| Storage | Use For | Speed | Durability | Search |
|---|---|---|---|---|
| **Mnesia** | Working memory, checkpoints, memos, run history | Sub-ms (in-BEAM) | Survives restart | Exact match, match_spec |
| **ContextFS** (CLI) | Long-term knowledge, cross-session recall | ~100ms (subprocess) | Survives everything | Semantic (ChromaDB), FTS5, hybrid |
| **Git + .md** | Artifact memory (OpenClaw already does this) | N/A (push) | Permanent | GitHub search |
| **Postgres** (future) | Production unified backend | ~5ms (network) | Durable | pgvector + tsvector |

Use all three for different things. Don't reimplement what ContextFS already does. Don't use ContextFS for things that need sub-ms access. The contract declares which backends.
