# Feature Plan: microsandbox Integration — Secure Agent Isolation via microVMs

## The Problem

Agent-OS has zero real isolation today. Every agent runs as a BEAM `Task.async` process with full access to:
- Host filesystem (`File.write!`, `File.read`, `File.rm_rf!`)
- Host network (outbound HTTPS, `System.cmd("git", ...)`, `System.cmd("gh", ...)`)
- Host credentials (`OPENAI_API_KEY`, `GITHUB_TOKEN`, `gh auth` session)
- Host binaries (`pdflatex`, `tectonic`, `git`, `gh`)

`ToolInterface.Sandbox` provides BEAM process isolation only — shared OS user, shared filesystem, shared network. The "sandbox" is aspirational, not actual. The `validate_url/1` blocklist is never called from the execution path. `CompletionHandler` runs four external binaries as the host user.

## The Solution: microsandbox

microsandbox provides hardware-level VM isolation using libkrun — each agent gets its own virtual machine with a dedicated kernel. Uses KVM on Linux, HVF (Apple Hypervisor.framework) on macOS. Boot times under 200ms. Runs standard OCI container images.

```bash
curl -sSL https://get.microsandbox.dev | sh
msb server start --dev
# Server runs on 127.0.0.1:6765
```

## Architecture

```
Your machine (Mac/Linux)
|
+-- microsandbox server (msb server start)
|   +-- Agent A's microVM --+
|   |   own kernel           |
|   |   own memory           +-- network access to host services only
|   |   own filesystem       |   (via gateway IP)
|   +-- Agent B's microVM --+
|   +-- Agent N's microVM --+
|
+-- Elixir orchestrator (BEAM node, port 4000)
|   +-- AgentScheduler.Agent GenServer --- manages --> microVM handle
|   +-- AgentOS.SharedMemory              <-- mediates all shared state
|   +-- ToolInterface.Capability          (gates VM access)
|   +-- ToolInterface.Audit               (logs every VM operation)
|   +-- PlannerEngine.Escrow              (cost-bounds operations)
|   +-- LLMClient                         (holds API keys, never in VM)
|
+-- ContextFS                              <-- long-term memory
|   +-- SQLite + FTS5                      (facts, decisions)
|   +-- ChromaDB                           (semantic search)
|   +-- Graph edges                        (decision lineage)
|
+-- Mnesia cluster                         <-- working memory
    +-- :agent_working_memory              (ETS-backed, fast)
    +-- :team_shared_state                 (disc_copies, durable)
```

### The Core Principle: microVMs Never Share Memory Directly

That's the whole point — each has its own kernel, own address space, hardware-enforced boundary. But agents working as a team need shared state. The resolution: **shared state lives outside the microVMs, in a layer agents access through the filesystem.**

## The Key Insight: The Interface is the Filesystem

Agents don't call memory APIs. They don't `POST /api/memory/write`. They read and write files. Claude Code reads `.md` files. OpenClaw writes `.tex` files. Every agent framework works with files. That's the universal interface.

So the memory layer must be invisible to the agent. The agent thinks it's working with files. The infrastructure makes those files smart.

```
Inside the microVM (what the agent sees):

/context/                    <-- mounted read-only, appears as plain files
  +-- brief.md              <-- task description + relevant history
  +-- prior-work.md         <-- filtered by relevance to current task
  +-- team-decisions.md     <-- actually generated from ContextFS query
  +-- guidelines.md         <-- agent spec guidelines

/workspace/                  <-- agent's working directory

/shared/output/              <-- mounted read-write, agent writes results here
  +-- report.md             <-- agent writes whatever it produces
  +-- findings.json
  +-- paper.tex
```

The agent never knows it's talking to ContextFS or Mnesia. It reads markdown from `/context/` and writes output to `/shared/output/`. The orchestrator prepares context before boot and ingests output after completion.

```
BEFORE VM boots:                          AFTER VM completes:

Orchestrator                              Orchestrator
  +-- Query ContextFS for relevant          +-- Scan /shared/output/
  |   decisions, prior work, context        +-- Parse each file (frontmatter,
  +-- Render as plain .md files             |   headers, content)
  +-- Mount into microVM as /context/       +-- Store in ContextFS with agent_id,
      (read-only)                           |   task_id, lineage
                                            +-- Update Mnesia working memory
                                            +-- Audit log entry
                                            +-- Notify orchestrator GenServer
```

This is what makes the architecture work with ANY agent — Claude Code, OpenClaw, custom scripts, whatever. They all read files and write files. The intelligence is in what context gets mounted and how output gets ingested.

## ContextFS: Orchestrator-Only (Option 2)

ContextFS runs on the host only. No ContextFS installed inside VMs. No MCP server needed from VMs. The orchestrator owns all ContextFS interaction via the `contextfs` CLI.

**Why orchestrator-only:**
- SQLite has no WAL mode — two processes writing = corruption
- ChromaDB uses file locks (`fcntl.LOCK_EX`) — cross-VM locking is unreliable
- The MCP server is a single-writer gateway, but agents don't need real-time memory during execution — pre-loaded context files are sufficient
- This matches the filesystem-as-interface pattern: agents read files, not APIs

```
BEFORE VM boot (orchestrator calls contextfs CLI on host):
  contextfs search "topic" --json         --> render as /context/prior-work.md
  contextfs list --type decision --json   --> render as /context/team-decisions.md
  contextfs search "topic" --type fact    --> render as /context/known-facts.md

DURING VM execution:
  Agent reads /context/*.md (plain files, no ContextFS)
  Agent writes output to /shared/output/*.md
  Agent calls BEAM LLM proxy at host:4000 (only HTTP call from VM)

AFTER VM completes (orchestrator calls contextfs CLI on host):
  contextfs save < /shared/output/findings.md --type fact --tags "agent:researcher"
  contextfs save < /shared/output/paper.tex --type code --tags "agent:writer"
  contextfs save --type agent_run --summary "Pipeline stage completed"
```

If agents later need real-time memory access during execution (not just pre-loaded context), we add the MCP server as an upgrade path. For now, the orchestrator handles everything.

## ContextBridge: The Translation Layer

```elixir
defmodule AgentOS.ContextBridge do
  @doc """
  Prepares the /context mount for an agent's microVM.
  Queries ContextFS via CLI for relevant context, renders as markdown files.
  Only the orchestrator calls contextfs — never the VM.
  """
  def prepare_context(task, agent_spec) do
    context_dir = Path.join(tmp_dir(), "context-#{task.id}")
    File.mkdir_p!(context_dir)

    # Pull relevant context from ContextFS via CLI (runs on host)
    relevant = contextfs_search(task.description, limit: 10)
    decisions = contextfs_search(task.description, type: "decision", limit: 5)
    prior_work = contextfs_search(task.description, type: "agent_run", limit: 5)

    # Render as plain markdown files the agent can just read
    render_md(context_dir, "brief.md", task_brief(task, agent_spec))
    render_md(context_dir, "prior-work.md", format_prior_work(prior_work))
    render_md(context_dir, "team-decisions.md", format_decisions(decisions))
    render_md(context_dir, "guidelines.md", agent_spec.guidelines)

    context_dir
  end

  @doc """
  After agent completes, ingests /shared/output back into ContextFS via CLI.
  Only the orchestrator calls contextfs — never the VM.
  """
  def ingest_output(task, agent_id, output_dir) do
    output_dir
    |> File.ls!()
    |> Enum.each(fn filename ->
      content = File.read!(Path.join(output_dir, filename))

      contextfs_save(content,
        type: infer_type(filename),
        tags: ["agent:#{agent_id}", "task:#{task.id}"],
        summary: extract_summary(content)
      )
    end)
  end

  defp contextfs_search(query, opts) do
    args = ["search", query, "--json", "--limit", to_string(Keyword.get(opts, :limit, 10))]
    args = if opts[:type], do: args ++ ["--type", opts[:type]], else: args

    case System.cmd("contextfs", args, stderr_to_stdout: true) do
      {json, 0} -> Jason.decode!(json)
      _ -> []
    end
  end

  defp contextfs_save(content, opts) do
    args = ["save", "--type", to_string(opts[:type])]
    args = if opts[:tags], do: args ++ ["--tags", Enum.join(opts[:tags], ",")], else: args
    args = if opts[:summary], do: args ++ ["--summary", opts[:summary]], else: args

    System.cmd("contextfs", args, input: content, stderr_to_stdout: true)
  end
end
```

Then launching an agent becomes:

```elixir
def run_agent(task, agent_spec) do
  # 1. Prepare context as plain files (orchestrator calls contextfs CLI on host)
  context_dir = ContextBridge.prepare_context(task, agent_spec)
  output_dir = create_output_dir(task.id)

  # 2. Launch microVM with mounts — no contextfs inside VM
  {:ok, sandbox} = MicroVM.create(%{
    image: agent_spec.image,
    volumes: [
      {context_dir, "/context", :ro},
      {output_dir, "/shared/output", :rw}
    ],
    cpus: 1,
    memory: 512
  })

  # 3. Run the agent's native command -- it just sees files
  MicroVM.exec(sandbox, agent_spec.command)
  # e.g., "researcher.sh" reads /context/brief.md, writes /shared/output/findings.md

  # 4. Ingest output back into ContextFS (orchestrator calls contextfs CLI on host)
  ContextBridge.ingest_output(task, agent_spec.id, output_dir)

  # 5. Cleanup
  MicroVM.stop(sandbox)
end
```

## Multi-Agent Team Flow

For a team of agents, each gets enriched context including previous agents' work:

```
Task comes in
  --> Orchestrator decomposes into subtasks
  --> For subtask 1 (Agent A: researcher):
      --> Query ContextFS for relevant context
      --> Render context as .md files in /context/
      --> Boot microVM, mount /context/ read-only
      --> Agent A runs, reads .md, writes findings to /shared/output/
      --> Orchestrator ingests output into ContextFS
  --> For subtask 2 (Agent B: reviewer):
      --> Query ContextFS (now includes Agent A's findings)
      --> Render enriched context as .md files
      --> Boot microVM, mount /context/ read-only
      --> Agent B reads Agent A's work as plain markdown
      --> Agent B writes review to /shared/output/
      --> Orchestrator ingests review into ContextFS
  --> Each agent is totally generic. The intelligence is in what context
      gets mounted and how output gets ingested.
```

## Three Layers of Shared Memory

Memory still has three layers, but the interface to agents is always files:

### Layer 1: Working Memory (Mnesia/ETS, milliseconds)

Hot state the orchestrator uses internally — escrow balances, agent states, job queue, capability tokens. Agents never access this directly. The orchestrator consults Mnesia when deciding what context to mount and when validating outputs.

### Layer 2: Long-Term Memory (ContextFS, seconds)

The bridge between files and structured memory. Before VM boot, ContextFS results are rendered as `/context/*.md`. After VM completes, `/shared/output/*` is ingested back into ContextFS with typed schemas, tags, lineage.

ContextFS graph lineage tracks which agent produced which output, enabling **decision archaeology** — if Agent A's work is invalidated, trace all downstream decisions that depended on it.

### Layer 3: Filesystem Artifacts (volume mounts)

The actual exchange mechanism. microsandbox mounts host directories into VMs:
- `/context/` — read-only, prepared by orchestrator
- `/shared/output/` — read-write, agent writes results
- `/workspace/` — agent's scratch space (ephemeral, destroyed with VM)

## What Gets Replaced, What Stays, What's New

### REPLACE (killed by microsandbox)

| Module | Why |
|---|---|
| `ToolInterface.Sandbox` | BEAM-only isolation replaced by real microVM isolation |
| `ToolInterface.Sandbox.validate_url/1` | Lexical URL blocklist replaced by network namespace enforcement at VM layer |

### KEEP (stays in BEAM, becomes MORE important)

| Module | New Role |
|---|---|
| `ToolInterface.Capability` | Gates memory access AND VM access, not just tool access |
| `ToolInterface.Audit` | Logs every memory read/write and VM operation per agent |
| `ToolInterface.Registry` | GenServer + tier model stays; `:sandbox` tier rewired to VM dispatch |
| `PlannerEngine.Escrow` | Cost-bounds VM time, memory operations, LLM calls (storage costs credits) |
| `AgentScheduler.Agent` | Full lifecycle GenServer stays; `Task.async` injection point becomes VM dispatch |
| `AgentScheduler.Evaluator` | Still scores agent quality — now with VM execution metrics |
| `MemoryLayer.Schema` | Type-validates what agents write to shared state |
| `MemoryLayer.Graph` | Lineage tracking for decision archaeology |
| `MemoryLayer.Version` | Versioned reads so agents see consistent snapshots |
| `LLMClient` | Holds API keys, makes LLM calls — NEVER runs inside VM |

### NEW (built for microsandbox)

| Module | Purpose |
|---|---|
| `AgentOS.MicroVM` | Elixir client wrapping microsandbox HTTP API |
| `AgentOS.MicroVM.Pool` | GenServer pool managing VM lifecycle (start/stop/health) |
| `AgentOS.MicroVM.Dispatch` | Replaces `Task.async` — submits jobs to VMs, awaits results |
| `AgentOS.ContextBridge` | Prepares /context/ mounts from ContextFS, ingests /shared/output/ back |
| `AgentOS.VMImage` | OCI image builder with agent runtime + tools (pdflatex, git, gh) |

## What Runs Where

### BEAM (trusted, holds secrets)

- Agent lifecycle management (GenServer state machine)
- LLM API calls (OpenAI, Anthropic, Ollama) — **API keys never enter a VM**
- Capability token creation and verification
- Escrow transactions
- Memory mediation (SharedMemory broker)
- Audit logging
- Contract validation
- Scheduling and evaluation

### microVM (isolated, stateless, untrusted)

- LaTeX generation (`write_latex`)
- PDF compilation (`pdflatex`, `tectonic`)
- Git operations (`git clone`, `git add`, `git commit`, `git push`)
- GitHub CLI (`gh repo create`, `gh repo view`)
- Code execution (`shell-exec`, `code-exec`, `python-exec`)
- File operations (`file-ops`)
- npm/package operations (`npm-run`)

### The Execution Split for OpenClaw

```
BEAM side (orchestrator):                  microVM side (isolated):

 AgentScheduler.Agent                       Agent Runtime Container

 1. plan_research()         --dispatch-->   4. write_latex()
    LLMClient.chat()                           File.write(.tex)

 2. execute_research()                      5. compile_pdf()
    LLMClient.chat()                           pdflatex / tectonic
                                               SelfRepair loop
 3. review_research()                          (LLM calls proxied back to BEAM)
    LLMClient.chat()
                            <--result--     6. ensure_repo()
 7. validate contract                          gh repo create
 8. record to memory
 9. update reputation                       7. push_artifacts()
                                               git clone/add/commit/push
```

LLM reasoning stays in BEAM (holds API keys). Artifact generation runs in VM (runs untrusted binaries). The `with` chain in `run_autonomous` gets split: steps 1-3 execute in BEAM, results are passed to VM for steps 4-7, VM returns artifacts, BEAM validates against contract.

## Credential Handling

**GitHub credentials cannot go into the VM raw.** Options:

1. **Short-lived tokens per job** — BEAM creates a GitHub App installation token (1-hour expiry), injects it into the VM environment. Token expires after the job.
2. **Proxy through BEAM** — VM calls back to BEAM's HTTP API for git operations. BEAM runs git on the host. More secure but higher latency.
3. **Fine-grained PAT per agent** — Create GitHub Personal Access Tokens scoped to specific repos. Less dynamic but simpler.

Recommendation: **Option 1 (short-lived tokens)** for production, **Option 3 (scoped PATs)** for local dev.

LLM API keys: **Never injected into VMs.** VM calls back to BEAM, BEAM makes LLM call, returns result.

## Network Policy

The microVM should have **no outbound internet access** except to the host services:

```
ALLOWED:
  host.internal:4000    <-- BEAM orchestrator API (memory, LLM proxy, status)
  host.internal:6765    <-- microsandbox control plane

BLOCKED:
  *:*                   <-- everything else (no direct internet from VM)
```

All external access (GitHub API, LLM APIs, package registries) is proxied through BEAM. Prevents data exfiltration, SSRF, unauthorized API calls, and direct access to Ollama on localhost.

## OCI Image for Agent VMs (Shared)

One shared image with all tools. Different agents use different entrypoints. No ContextFS in the image — the orchestrator handles all ContextFS interaction on the host.

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    tectonic \
    git \
    gh \
    python3 python3-pip \
    nodejs npm \
    curl jq \
    && rm -rf /var/lib/apt/lists/*

# Agent scripts (researcher, writer, publisher — different entrypoints)
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Default working directory
WORKDIR /workspace
```

Each agent stage specifies its entrypoint:
- Researcher: `/usr/local/bin/researcher.sh`
- Writer: `/usr/local/bin/writer.sh`
- Publisher: `/usr/local/bin/publisher.sh`

The VM reads `/context/` (read-only mount), writes `/shared/output/` (read-write mount), and calls the BEAM LLM proxy at `host.internal:4000` for LLM access. No other network access. No ContextFS CLI inside the VM.

---

## Phase 1: Local microVM Execution (Replace Task.async)

Goal: One agent job runs inside a microsandbox microVM instead of a BEAM Task. Prove the architecture works end-to-end.

### Feature 1.1: microsandbox Elixir Client

**What it does.** New module `AgentOS.MicroVM` wraps the microsandbox HTTP API via `:httpc`. Operations: `create/2` (start VM from OCI image), `exec/2` (run command in VM), `write_file/3` (inject file into VM), `read_file/2` (extract file from VM), `stop/1` (destroy VM).

**Why it matters.** This is the bridge between BEAM and microVMs. Every other feature depends on this client.

**Dependencies.** microsandbox installed and running (`msb server start --dev`).

### Feature 1.2: Agent VM Dispatch

**What it does.** Replaces the `Task.async` call in `AgentScheduler.Agent.handle_info({:execute_autonomous, job})` with a VM dispatch path. The GenServer creates a microVM, injects the job spec and credentials, monitors execution, receives results, and destroys the VM.

The `task_ref` pattern is preserved — `Process.monitor` on a spawned process that manages the VM lifecycle, so the GenServer's existing `handle_info({ref, result})` and `handle_info({:DOWN, ...})` handlers work unchanged.

**Why it matters.** This is the single injection point. All agent execution flows through `handle_info({:execute_autonomous, job})`. Changing this one call site puts all dangerous computation inside microVMs.

**Dependencies.** Feature 1.1 (MicroVM client).

### Feature 1.3: OCI Image Build

**What it does.** Creates a Dockerfile for the agent runtime image. Includes tectonic/pdflatex, git, gh CLI, Python, Node. Contains an `agent-runtime` script that reads job JSON, executes the artifact pipeline, and writes result JSON.

**Why it matters.** The VM needs a pre-built image with all tools. One-time build per release.

**Dependencies.** Docker installed locally.

### Feature 1.4: Artifact Exchange

**What it does.** Defines how artifacts (.tex, .pdf, README.md) move between VM and host. Two options:
- **File API**: VM writes to local path, BEAM reads via `MicroVM.read_file/2`
- **Volume mount**: Shared host directory mounted into VM, BEAM reads directly

Result is the same: `AgentRunner` gets artifact paths on the host filesystem for contract validation (`ResearchContract.verify/1` checks `File.exists?(tex_path)`).

**Dependencies.** Feature 1.2 (VM dispatch).

### Feature 1.5: Replace ToolInterface.Sandbox

**What it does.** Removes the BEAM-only `ToolInterface.Sandbox` module. Rewires `:sandbox` tier tools in `ToolInterface.Registry` to dispatch through `AgentOS.MicroVM` instead of `spawn_monitor`.

**Why it matters.** Eliminates the false sense of security. Every "sandboxed" tool now runs with real hardware isolation.

**Dependencies.** Feature 1.1 (MicroVM client).

### Feature 1.6: microsandbox Health Gate

**What it does.** Before any agent execution, verify microsandbox is running. If not, fail fast with a clear error — no silent fallback to BEAM execution. All agents MUST run in microVMs, no exceptions.

```elixir
case AgentOS.MicroVM.health() do
  :ok -> dispatch_to_vm(job, state)
  {:error, reason} ->
    Logger.error("microsandbox not available: #{inspect(reason)} - agent execution requires microVM")
    {:error, :microsandbox_not_running}
end
```

**Why no fallback.** The whole point of microVM isolation is security. A fallback to `Task.async` silently removes the isolation guarantee. If microsandbox isn't running, the operator needs to know and fix it.

**Dependencies.** Feature 1.1 (MicroVM client health check).

---

## Phase 2: ContextBridge + Credential Isolation

Goal: Context flows to agents as files, output flows back as structured memory. Credentials are short-lived and scoped.

### Feature 2.1: ContextBridge — Pre-Boot Context Rendering

**What it does.** `AgentOS.ContextBridge.prepare_context/2` queries ContextFS via CLI for relevant context (decisions, prior work, team state), renders results as plain `.md` files, and returns the directory path for mounting into the microVM as `/context/` (read-only).

The agent sees `brief.md`, `prior-work.md`, `team-decisions.md`, `guidelines.md` — plain markdown. It never knows these were generated from a semantic search across structured memory.

**Why it matters.** This is the universal agent interface. Claude Code reads `.md` files. OpenClaw reads `.md` files. Any agent reads files. No custom API integration needed. The intelligence is in what context gets mounted.

**Dependencies.** Phase 1 (VMs running), ContextFS CLI installed.

### Feature 2.2: ContextBridge — Post-Run Output Ingestion

**What it does.** `AgentOS.ContextBridge.ingest_output/3` scans `/shared/output/` after the agent completes, parses each file (detecting type from extension, frontmatter, and content), and stores in ContextFS with agent_id, task_id, and lineage tags. Also updates Mnesia working memory and emits audit entries.

**Why it matters.** Agent output becomes searchable structured memory. The next agent that runs on a similar topic will find this output in its `/context/` mount.

**Dependencies.** Feature 2.1 (context rendering creates the lineage chain).

### Feature 2.3: LLM Proxy API

**What it does.** HTTP endpoint that VMs call when they need LLM assistance (e.g., SelfRepair fix loop):

```
POST http://host.internal:4000/api/v1/vm/llm/chat
{"messages": [...], "model": "gpt-4o", "max_tokens": 8192}
Authorization: Bearer <job_capability_token>
```

BEAM validates the token, calls `LLMClient.chat/2` with the real API key, returns the result. API keys never enter the VM. This is the ONE endpoint agents call via HTTP — everything else is filesystem.

**Dependencies.** Phase 1, `LLMClient` (existing module).

### Feature 2.3: Short-Lived GitHub Tokens

**What it does.** Before dispatching a job to a VM, the orchestrator creates a short-lived GitHub token (1-hour expiry, scoped to AgentHeroWork org). Injected as `GH_TOKEN` env var in the VM. Expires after job completes.

**Dependencies.** Phase 1, GitHub App setup.

### Feature 2.4: VM Network Policy

**What it does.** Configures microsandbox network rules: ALLOW host.internal:4000 and :6765, BLOCK everything else. All external access proxied through BEAM.

**Dependencies.** microsandbox network policy configuration.

### Feature 2.5: Per-Job Capability Tokens

**What it does.** Extends `ToolInterface.Capability` to issue per-job tokens bundling tool access, memory access (read/write scopes), LLM access (models, token budget), and time budget (VM max lifetime). When the token expires, the VM loses all access.

**Dependencies.** Feature 2.1 (SharedMemory API needs token verification).

---

## Phase 3: Multi-Agent VM Orchestration

Goal: Multiple agents in separate VMs collaborate through shared memory, with the BEAM orchestrating the team.

### Feature 3.1: VM Pool Manager

**What it does.** `AgentOS.MicroVM.Pool` GenServer manages a pool of microVMs. Pre-warms VMs for fast dispatch. Tracks active VMs, enforces max concurrent VMs, handles cleanup of orphaned VMs.

**Dependencies.** Phase 1 (MicroVM client).

### Feature 3.2: Team Shared State

**What it does.** Team-scoped namespaces in `AgentOS.SharedMemory`. All agents in a contract team get read/write access to `team:{contract_id}` namespace. One agent's findings immediately visible to teammates.

**Dependencies.** Feature 2.1 (SharedMemory API), Feature 2.5 (capability tokens with scope).

### Feature 3.3: Agent-to-Agent Messaging via Orchestrator

**What it does.** Message-passing endpoints:
```
POST /api/v1/vm/message/send   {"to": "agent-b", "content": {...}}
GET  /api/v1/vm/message/inbox
```

Messages stored in Mnesia, delivered on poll or via SSE. Orchestrator mediates — agents can only message teammates.

**Dependencies.** Feature 3.2 (team shared state), chat dynamics plan.

### Feature 3.4: VM Metrics and Cost Tracking

**What it does.** Per-VM metrics: CPU time, memory usage, network bytes, wall-clock duration. Feeds into `AgentScheduler.Evaluator` for quality scoring and `PlannerEngine.Escrow` for credit deduction.

**Dependencies.** microsandbox metrics API, `AgentScheduler.Evaluator`.

### Feature 3.5: Production Deployment (Fly.io + microsandbox)

**What it does.** Packages the Elixir orchestrator as a Fly Machine running microsandbox. Each agent job spins up a nested microVM. Alternatively, each agent gets its own Fly Machine.

**Dependencies.** Fly.io deployment plan, all Phase 1-2 features.

---

## Implementation Order

```
Phase 1 (Weeks 1-3) -- Prove the architecture
  1.1 microsandbox Elixir client (HTTP wrapper)
  1.2 Agent VM dispatch (replace Task.async — microVM only, no fallback)
  1.3 Shared OCI image build (debian + pdflatex + git + gh + python + node)
  1.4 Artifact exchange (VM to host via volume mounts)
  1.5 Replace ToolInterface.Sandbox
  1.6 microsandbox health gate (fail fast if not running)

Phase 2 (Weeks 4-6) -- ContextBridge + credential isolation
  2.1 ContextBridge pre-boot context rendering (contextfs CLI on host -> .md -> /context/)
  2.2 ContextBridge post-run output ingestion (/shared/output/ -> contextfs CLI on host)
  2.3 LLM proxy API (only HTTP endpoint agents call, API keys stay in BEAM)
  2.4 Short-lived GitHub tokens injected as env var in VM
  2.5 VM network policy (block all except host)
  2.6 Per-job capability tokens

Phase 3 (Weeks 7-10) -- Multi-agent pipeline
  3.1 VM pool manager
  3.2 Multi-stage pipeline orchestrator (researcher -> writer -> publisher)
  3.3 ResearchPipelineContract with stages + artifact validation
  3.4 VM metrics and cost tracking
  3.5 Production deployment (Fly.io)
```

## What the Existing Codebase Becomes

The sandbox code gets replaced by microsandbox. But the orchestration and memory mediation become **more important, not less**, because now they're the only way agents interact with shared state. The isolation makes the mediation layer essential rather than optional.

| What already exists | New role with microVMs |
|---|---|
| `ToolInterface.Capability` | Gates memory AND VM access |
| `ToolInterface.Audit` | Logs every VM operation per agent |
| `PlannerEngine.Escrow` | Cost-bounds VM time and memory ops |
| `MemoryLayer.Schema` | Type-validates what agents write to shared state |
| `MemoryLayer.Graph` | Lineage tracking for decision archaeology |
| `MemoryLayer.Version` | Versioned reads so agents see consistent snapshots |
| `ContextFS` | Long-term persistent memory backend |
| `AgentScheduler.Agent` | Lifecycle GenServer: now manages VM handle instead of Task ref |
| `AgentScheduler.Evaluator` | Quality scoring with VM execution metrics |

microsandbox gives us isolated boxes. ContextFS translates between files and structured memory. The Elixir orchestrator coordinates agents and manages escrow/reputation. The agents themselves are off-the-shelf — OpenClaw, Claude Code, whatever. They never need to be customized. They just read files and write files, which they already do.

## The Real Stack

```
microsandbox          <-- runs agents in isolated microVMs
ContextFS             <-- translates between files and structured memory
Elixir orchestrator   <-- coordinates agents, manages escrow/reputation
```

Three components, each doing one thing. The agents are generic. The intelligence is in what context gets mounted and how output gets ingested. That's the orchestrator's job, and that's where the Elixir layer earns its keep.

## Module Map

| New Module | OTP App | Purpose |
|---|---|---|
| `AgentOS.MicroVM` | agent_os | Elixir HTTP client for microsandbox API |
| `AgentOS.MicroVM.Pool` | agent_os | VM pool lifecycle management |
| `AgentOS.MicroVM.Dispatch` | agent_os | Replaces Task.async with VM job submission |
| `AgentOS.ContextBridge` | agent_os | Renders ContextFS into /context/ .md files, ingests /shared/output/ back |
| `AgentOS.VMImage` | agent_os | OCI image builder for agent runtime |

| Replaced Module | Replacement |
|---|---|
| `ToolInterface.Sandbox` | `AgentOS.MicroVM.Dispatch` |

| Modified Module | Change |
|---|---|
| `AgentScheduler.Agent` | `handle_info(:execute_autonomous)` dispatches to VM or Task (fallback) |
| `ToolInterface.Registry` | `:sandbox` tier `execute:` lambdas call `MicroVM.exec` |
| `ToolInterface.Capability` | Move signing key to config; extend tokens with memory/LLM/VM scopes |
| `AgentOS.AgentRunner` | Split `run_autonomous` into BEAM steps (LLM) + VM steps (artifacts) |
| `OpenClaw` | Steps 1-3 (LLM) in BEAM, steps 4-7 (artifacts) dispatched to VM |
| `NemoClaw` | Same split + guardrail checks stay in BEAM |
| `CompletionHandler` | Runs inside VM -- no changes to module, just where it executes |
| `SelfRepair` | Runs inside VM -- LLM calls proxied through BEAM API |
