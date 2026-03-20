# BUILD PLAN: Generic Contract Layer + Multi-Agent Pipeline

## Control Methodology: AAPEV

```
A - ASSESS    What exactly needs to change? What's broken? What exists?
A - ANALYZE   Read the code. Trace the call graph. Identify every touchpoint.
P - PLAN      Show the changes. Get approval. No code until plan is confirmed.
E - EXECUTE   Write the code. Compile. Zero warnings.
V - VALIDATE  Tests pass. End-to-end works. Real output produced.
```

**Confidence:** HIGH = end-to-end verified | MEDIUM = compiles + unit tests | LOW = untested | UNKNOWN = design only

---

## Architecture: Node CLI → Elixir Server → microVM

```
Node CLI (cli/)                     Elixir Server (port 4000)           microVM (microsandbox)
────────────────                    ────────────────────────            ──────────────────────
agent-os run pipeline               POST /api/v1/pipeline/run           stage 1: researcher.sh
  --contract research-report         → Pipeline.run(contract, input)     reads /context/*.md
  --topic "oil and gas"              → for each stage:                   calls LLM proxy
                                       ContextBridge.prepare_context()   writes /shared/output/
agent-os run openclaw                  MicroVM.run_agent()
  --topic "particle physics"           ContextBridge.ingest_output()    stage 2: writer.sh
                                     → Verify artifacts                  reads findings from ctx
                                     → Return results                    writes paper.tex/.pdf

                                                                        stage 3: publisher.sh
                                                                         creates GitHub repo
                                                                         pushes artifacts
```

**The Node CLI is an HTTP client.** It does NOT run Elixir code. It calls `POST /api/v1/pipeline/run` and `POST /api/v1/run`. The Elixir server handles all execution.

**The Elixir CLI (`src/agent_os_cli/`) will be removed.** It was a workaround for direct execution. The proper path is: Node CLI → HTTP → Elixir server → microVM.

---

## Current State (Honest)

### What works:
- Node CLI: `agent-os agent create/list/start/stop/logs`, `agent-os job submit`, `agent-os health` — all HTTP to server
- Elixir server: REST API, AgentRunner, OpenClaw/NemoClaw, LLM proxy endpoint
- Elixir CLI: `mix run -e 'AgentOS.CLI.main(["run", "openclaw", ...])'` — in-process execution (to be removed)
- microsandbox: `msb exe alpine:latest` with volumes, env vars, `--scope any` — proven working
- VMController: `/api/v1/vm/llm/chat` — LLM proxy for microVMs, wired and working

### What's orphaned:
- `AgentOS.MicroVM` — zero callers
- `AgentOS.ContextBridge` — zero callers
- `AgentOS.Pipeline` — just created, zero callers
- `sandbox/scripts/*.sh` — manual bash demo only

### What's missing:
- `POST /api/v1/run` endpoint — single agent run via HTTP
- `POST /api/v1/pipeline/run` endpoint — multi-stage pipeline via HTTP
- Node CLI `run` command
- Node CLI `pipeline` command
- Pipeline → MicroVM → ContextBridge wiring
- Elixir CLI removal

---

## Build Phases

```
Phase 0: Safety hooks                               [sequential]
    │
Phase 1: ContractSpec + Loader + Verify (server)     [sequential, gate]
    │
    ├── Phase 2A: Pipeline wiring (server)           [PARALLEL]
    │   Wire Pipeline → MicroVM → ContextBridge
    │   Add POST /api/v1/pipeline/run endpoint
    │   Add POST /api/v1/run endpoint
    │
    ├── Phase 2B: Node CLI migration                 [PARALLEL]
    │   Add `run` and `pipeline` commands
    │   Remove Elixir CLI (agent_os_cli)
    │
    ├── Phase 2C: YAML contract templates            [PARALLEL]
    │   research-report.yaml
    │   market-dashboard.yaml
    │
    ├───────────────────────────────────────────────┘
    │
Phase 3: ContextFS scoped memory                    [sequential, needs 2A]
    │
Phase 4: End-to-end validation                      [sequential, needs all]
    │   Oil & gas pipeline through Node CLI → HTTP → server → microVM
```

---

### Phase 0: Blueprint Safety
- Create `scripts/validate-phase.sh` — compile + test gate
- Already done ✓

---

### Phase 1: ContractSpec (Server-Side)

**Goal:** Contracts are data (maps/YAML), not hardcoded Elixir modules.

**Files created:**
- `agent_os/lib/agent_os/contracts/contract_spec.ex` — struct with stages, verify rules, memory config ✓
- `agent_os/lib/agent_os/contracts/verify.ex` — generic artifact verification ✓
- `agent_os/lib/agent_os/contracts/loader.ex` — loads from YAML/map ✓
- `agent_os/lib/agent_os/pipeline.ex` — multi-stage orchestrator ✓

**Files modified:**
- `agent_os/lib/agent_os/agent_runner.ex` — accepts `%ContractSpec{}` in addition to modules ✓

**VALIDATE gate:**
- [ ] `mix compile --warnings-as-errors` — zero warnings across all apps
- [ ] All existing tests pass
- [ ] `ContractSpec.from_map(%{name: "test", ...})` returns `{:ok, spec}`
- [ ] `AgentRunner.run(spec, %ContractSpec{...}, job)` validates artifacts
- [ ] `agent-os run openclaw --topic "test"` via Elixir CLI still works (until removed)

---

### Phase 2A: Pipeline Wiring (Server-Side) [PARALLEL]

**Goal:** HTTP endpoints that trigger pipeline execution via MicroVM + ContextBridge.

**New endpoints:**
```
POST /api/v1/run
  body: {type: "openclaw", topic: "...", model: "gpt-4o"}
  → AgentRunner.run() with the appropriate agent module
  → returns {artifacts: {...}}

POST /api/v1/pipeline/run
  body: {contract: "research-report", topic: "...", env: {...}}
  → Loader.load(contract) → Pipeline.run(spec, input)
  → returns {artifacts: {...}, stages_completed: [...]}

GET /api/v1/contracts
  → Loader.list() — list available contract templates
```

**New controller:**
- `agent_os_web/controllers/run_controller.ex` — handles `/run` and `/pipeline/run`

**Wiring:**
- `Pipeline.run()` calls `MicroVM.run_agent()` (no longer orphaned)
- `Pipeline.run()` calls `ContextBridge.prepare_context/ingest_output` (no longer orphaned)

**VALIDATE gate:**
- [ ] `curl -X POST localhost:4000/api/v1/run -d '{"type":"openclaw","topic":"test"}'` works
- [ ] `curl -X POST localhost:4000/api/v1/pipeline/run -d '{"contract":"research-report","topic":"test"}'` runs stages in microVMs
- [ ] `MicroVM` module has callers — no longer orphaned
- [ ] `ContextBridge` module has callers — no longer orphaned

---

### Phase 2B: Node CLI Migration [PARALLEL]

**Goal:** Node CLI has `run` and `pipeline` commands. Elixir CLI removed.

**New file:**
- `cli/src/commands/run.js` — `run` and `pipeline` subcommands

```javascript
// agent-os run openclaw --topic "particle physics"
export async function run(args, opts) {
  const type = args[0];
  const result = await http.post('/api/v1/run', {
    type,
    topic: opts.topic,
    model: opts.model,
    provider: opts.provider,
  }, opts);
  // display results
}

// agent-os run pipeline --contract research-report --topic "oil and gas"
export async function pipeline(args, opts) {
  const result = await http.post('/api/v1/pipeline/run', {
    contract: opts.contract,
    topic: opts.topic,
  }, opts);
  // display stage results
}
```

**Modified files:**
- `cli/src/main.js` — add `run` case with `--topic`, `--contract`, `--model`, `--provider` opts
- `cli/package.json` — no changes needed (already uses Node 18+ fetch)

**Removed:**
- `src/agent_os_cli/` — entire directory removed
- References in other mix.exs files updated

**New CLI flags:**
```
--topic <topic>       Research/task topic
--contract <name>     Contract name for pipeline mode
--model <model>       LLM model override
--provider <provider> LLM provider (openai, anthropic, ollama)
--output-dir <dir>    Output directory override
```

**VALIDATE gate:**
- [ ] `agent-os run openclaw --topic "test"` works via Node CLI → HTTP → server
- [ ] `agent-os run pipeline --contract research-report --topic "test"` works
- [ ] `agent-os run --help` shows both single and pipeline usage
- [ ] `node --test cli/test/` passes (new tests for run command)
- [ ] Elixir CLI removed, no references remain

---

### Phase 2C: YAML Contract Templates [PARALLEL]

**Goal:** Two ready-to-use contract templates.

**New files:**
- `agent_os/priv/contracts/research-report.yaml`
- `agent_os/priv/contracts/market-dashboard.yaml`

```yaml
# research-report.yaml
name: research-report
description: Multi-agent research pipeline producing a paper and GitHub repo
stages:
  - name: researcher
    instructions: |
      Research the given topic. Produce comprehensive findings with sources.
      Write findings as markdown to /shared/output/findings.md
    output:
      - findings.md
  - name: writer
    instructions: |
      Read /context/findings.md. Generate a LaTeX paper and compile to PDF.
      Write paper.tex and README.md to /shared/output/
    input_from: researcher
    output:
      - paper.tex
      - README.md
  - name: publisher
    instructions: |
      Create a GitHub repo and push all artifacts from /context/.
      Write the repo URL to /shared/output/repo_url.txt
    input_from: writer
    output:
      - repo_url.txt
required_artifacts:
  - findings_md
  - paper_tex
  - repo_url_txt
verify:
  - file_exists: findings.md
  - min_bytes:
      file: paper.tex
      size: 500
credentials:
  - github_token
memory:
  load_past_runs: 5
  load_procedures: 3
  knowledge_base: false
  search_mode: semantic
max_retries: 2
```

**VALIDATE gate:**
- [ ] `Loader.load("research-report")` returns valid `%ContractSpec{}`
- [ ] `Loader.load("market-dashboard")` returns valid `%ContractSpec{}`
- [ ] `curl localhost:4000/api/v1/contracts` lists both

---

### Phase 3: ContextFS Scoped Memory

**Goal:** Orchestrator calls ContextFS before/after each pipeline stage with typed scoping.

**Memory scoping tiers:**

```
TIER 1 — Same contract + similar topic (always loaded)
  contextfs search "{topic}" --tags "contract:{name}" --limit 5

TIER 2 — Same contract, any topic (always loaded)
  contextfs search "procedures lessons" --tags "contract:{name}" --type procedural --limit 3

TIER 3 — Cross-contract knowledge (opt-in via knowledge_base: true)
  contextfs search "{topic}" --tags "knowledge-base" --limit 3

NEVER: unrelated contract runs, other agents' checkpoints
```

**Tagging on ingest:**
```
contextfs save --type fact --tags "contract:{name},stage:{stage},run:{id}"
```

**VALIDATE gate:**
- [ ] Pipeline run #1: ingests findings with contract/stage tags
- [ ] Pipeline run #2 (same topic): gets enriched context from run #1
- [ ] Pipeline run #3 (different topic): does NOT get unrelated context
- [ ] `contextfs search "topic" --tags "contract:research-report"` returns scoped results

---

### Phase 4: End-to-End Validation — Oil & Gas Live Dashboard

**Goal:** Produce a live Vercel website with oil & gas market research, news feed, and charts. All execution in microVMs, all auth injected, no workarounds.

```bash
agent-os run pipeline \
  --contract market-dashboard \
  --topic "oil and gas market analysis — crude prices, natural gas, industry news"
```

**What gets produced:**
1. **Researcher** (microVM) → `findings.md` (detailed market analysis), `prices.json` (structured price data), `news.json` (headlines + sources)
2. **Developer** (microVM) → `app/` directory with modern, mobile-friendly single-page dashboard using Chart.js + Tailwind via CDN. Real charts, news feed, market summary.
3. **Deployer** (microVM) → Deploys to Vercel + pushes to GitHub repo. Returns live URL.

**Auth injection (contract declares, orchestrator resolves):**
```yaml
credentials:
  - github_token     # resolved: gh auth token → GH_TOKEN env var in VM
  - vercel_token     # resolved: VERCEL_TOKEN env var → VERCEL_TOKEN in VM
```

The orchestrator resolves each credential from the host environment and injects them as env vars into the microVM. VMs never access host auth directly. The contract declares WHAT credentials are needed, the orchestrator handles HOW to get them.

**Pipeline.build_env/3 resolves credentials:**
```elixir
if :vercel_token in contract.credentials do
  case System.get_env("VERCEL_TOKEN") do
    nil -> base  # skip if not set
    token -> Map.put(base, "VERCEL_TOKEN", token)
  end
end
```

**Pre-requisites:**
- `VERCEL_TOKEN` env var set (create at https://vercel.com/account/tokens)
- `OPENAI_API_KEY` env var set
- `msb server start --dev` running
- `contextfs server start chroma` running
- Elixir server running on port 4000

**VALIDATE gate (FINAL):**
- [ ] Node CLI: `agent-os run pipeline --contract market-dashboard --topic "oil and gas"`
- [ ] Server loads contract from YAML
- [ ] Pipeline runs 3 stages in separate microVMs
- [ ] Researcher produces real market data (findings.md, prices.json, news.json)
- [ ] Developer produces modern mobile-friendly dashboard (app/index.html)
- [ ] Deployer pushes to GitHub AND deploys to Vercel
- [ ] Live Vercel URL is accessible and shows dashboard with charts + news
- [ ] GitHub repo has all artifacts
- [ ] ContextFS has tagged memories (contract:market-dashboard, stage:researcher, etc.)
- [ ] Slack notification sent to #agenthero with live URL

---

## Anti-Hallucination Checklist (Every Phase)

- [ ] Did I READ the files before modifying?
- [ ] Did I TRACE the call graph from CLI → HTTP → server → output?
- [ ] Are there ZERO orphaned modules in the execution path?
- [ ] Does `mix compile --warnings-as-errors` pass for ALL apps?
- [ ] Do ALL tests pass?
- [ ] Is ContextFS actually CALLED (not just referenced)?
- [ ] Is MicroVM actually CALLED (not just referenced)?
- [ ] Does the Node CLI (`agent-os`) work, not just the Elixir CLI?
- [ ] Would I bet $100 this works if someone else ran it right now?

---

## Files Summary

### Create
| File | Phase | Purpose |
|------|-------|---------|
| `agent_os/lib/agent_os/contracts/contract_spec.ex` | 1 ✓ | Data-driven contract struct |
| `agent_os/lib/agent_os/contracts/loader.ex` | 1 ✓ | Load from YAML/map |
| `agent_os/lib/agent_os/contracts/verify.ex` | 1 ✓ | Generic artifact checks |
| `agent_os/lib/agent_os/pipeline.ex` | 1 ✓ | Multi-stage orchestrator |
| `agent_os_web/controllers/run_controller.ex` | 2A | HTTP endpoints for run/pipeline |
| `cli/src/commands/run.js` | 2B | Node CLI run + pipeline commands |
| `agent_os/priv/contracts/research-report.yaml` | 2C | Research contract template |
| `agent_os/priv/contracts/market-dashboard.yaml` | 2C | Dashboard contract template |

### Modify
| File | Phase | Change |
|------|-------|--------|
| `agent_os/lib/agent_os/agent_runner.ex` | 1 ✓ | Accept `%ContractSpec{}` |
| `agent_os_web/lib/agent_os_web/router.ex` | 2A | Add `/run`, `/pipeline/run`, `/contracts` routes |
| `cli/src/main.js` | 2B | Add `run` command routing + new opts |

### Remove
| File | Phase | Reason |
|------|-------|--------|
| `src/agent_os_cli/` (entire directory) | 2B | Replaced by Node CLI + HTTP endpoints |

---

## Parallel Execution Map

```
Phase 0 ─── Phase 1 ───┬─── Phase 2A (server wiring)  ──┐
                        │                                  │
                        ├─── Phase 2B (Node CLI)     ─────┤── Phase 3 ── Phase 4
                        │                                  │
                        └─── Phase 2C (YAML templates) ──┘
```

Phases 2A, 2B, 2C are fully independent and can run in parallel.
Phase 3 needs 2A (pipeline must run to test ContextFS).
Phase 4 needs all (full stack validation).
