# Agent-OS Architecture Restructure v1

## Execution Strategy — AI Agent Time

AI agents work in parallel, not sequentially. Each phase runs as concurrent coding teams with explicit dependency gates.

```
Timeline (AI agent minutes, not human weeks):

T+0      ──── Phase 1A + 1B + 1C launch in parallel ────
         │                                                │
T+15     ──── Gate: compile + test (198 tests pass) ─────
         │                                                │
T+15     ──── Phase 2A + 2B + 2C launch in parallel ────
         │                                                │
T+30     ──── Gate: compile + test + integration ────────
         │                                                │
T+30     ──── Phase 3A + 3B launch in parallel ─────────
         │                                                │
T+50     ──── Gate: E2E pipeline works via Node CLI ────
         │                                                │
T+50     ──── Phase 4 (agent-hero worktree) ────────────
         │                                                │
T+65     ──── Final gate: marketplace integration ──────
```

---

## Phase 1: Fix the Foundation (T+0 to T+15)

### Team 1A: Dependency Flip + Merge agent_scheduler into agent_os
**Worktree:** agent-os (isolation: worktree)

Tasks:
1. Remove `{:agent_os_web, path: "../agent_os_web"}` from `agent_os/mix.exs`
2. Add `{:agent_os, path: "../agent_os"}` to `agent_os_web/mix.exs`
3. Remove `apply/3` workarounds in `RunController` — use direct module calls
4. Move from `agent_scheduler` into `agent_os`:
   - `agents/openclaw.ex` → `agent_os/lib/agent_os/agents/openclaw.ex`
   - `agents/nemoclaw.ex` → `agent_os/lib/agent_os/agents/nemoclaw.ex`
   - `agents/completion_handler.ex` → `agent_os/lib/agent_os/agents/completion_handler.ex`
   - `agents/self_repair.ex` → `agent_os/lib/agent_os/agents/self_repair.ex`
   - `agents/agent_type.ex` → `agent_os/lib/agent_os/agents/agent_type.ex`
   - `llm_client.ex` → `agent_os/lib/agent_os/llm_client.ex`
   - `research_prompts.ex` → `agent_os/lib/agent_os/research_prompts.ex`
5. Update all module references (namespaces change)
6. Keep `agent_scheduler` as ONLY: Agent GenServer, Supervisor, Registry, Scheduler, Evaluator, Pipeline(EventEmitter)
7. Compile + test

**GATE:** `mix compile --warnings-as-errors` passes for agent_os, agent_os_web, agent_scheduler

### Team 1B: Delete Dead Code + Fix Bugs
**Worktree:** agent-os (isolation: worktree)

Tasks:
1. Delete `AgentScheduler.Agents.Runtime` (never called)
2. Delete `AgentOS.submit_job/1` (calls OrderBook but nothing responds)
3. Delete `AgentScheduler.Pipeline` (EventEmitter, conflicts with AgentOS.Pipeline naming)
4. Fix `PlannerEngine.Escrow.settle(:release)` — add operator credit transfer
5. Merge `AgentScheduler.Evaluator` dimensions with `PlannerEngine.Reputation` dimensions into one unified system
6. Fix `OrderBook.cost_functional` to use real reputation instead of default 0.5
7. Compile + test

**GATE:** All existing tests pass. Escrow settle correctly transfers credits.

### Team 1C: Wire Disconnected Systems
**Worktree:** agent-os (isolation: worktree)

Tasks:
1. Connect `AgentOS.Pipeline` completion → `Evaluator.evaluate` (score agents after runs)
2. Connect `Evaluator` scores → `Reputation.record_quality` (unified)
3. Connect `MemoryLayer` to `ContextBridge` — Mnesia as fast working memory layer
4. Wire `ToolInterface.Capability` into `Pipeline.build_env` — agents get capability tokens
5. Add `AgentScheduler.Scheduler` dispatch loop (GenServer `handle_info(:dispatch)` with `Process.send_after`)
6. Compile + test

**GATE:** Pipeline run creates evaluation + reputation entries. Scheduler drains queue.

---

## Phase 2: Phoenix Upgrade + API Hardening (T+15 to T+30)

### Team 2A: Phoenix Migration
**Worktree:** agent-os (isolation: worktree)

Tasks:
1. Add Phoenix deps: `{:phoenix, "~> 1.7"}`, `{:phoenix_live_view, "~> 1.0"}`, `{:phoenix_pubsub, "~> 2.0"}`
2. Create `AgentOS.Web.Endpoint` with WebSocket transport
3. Convert `Plug.Router` → `Phoenix.Router` with pipelines
4. Migrate all controllers to Phoenix controller pattern
5. Add `Phoenix.PubSub` — Pipeline publishes events, SSE endpoint subscribes
6. Add SSE endpoint: `GET /api/v1/pipeline/:id/events`
7. Add CORS plug for NextJS origin
8. Compile + test

**GATE:** Health endpoint responds. Pipeline events stream via SSE.

### Team 2B: API Hardening
**Worktree:** agent-os (isolation: worktree)

Tasks:
1. Add pagination to all list endpoints (cursor-based)
2. Fix `JobController.show` — implement real job status tracking
3. Add `POST /api/v1/auth/exchange` — Supabase JWT → agent-os scoped token
4. Add request IDs for distributed tracing
5. Replace hand-rolled YAML parser with `yaml_elixir` (AOS-21)
6. Add `POST /api/v1/escrow/set_balance` — credit top-up endpoint
7. Compile + test

**GATE:** All API endpoints respond correctly. YAML parser handles full spec.

### Team 2C: Node CLI Upgrade
**Worktree:** agent-os (isolation: worktree, cli/ only)

Tasks:
1. Add `--follow` streaming on `agent-os run` (SSE client)
2. Add `~/.agent-os/config.json` for persistent credentials
3. Add `agent-os login` / `agent-os logout` token management
4. Add progress output during pipeline runs
5. Fix `docker-compose` → `docker compose` (v2 syntax)
6. Add `agent-os audit <pipeline-id>` command
7. Add `agent-os contracts list` command
8. Test all commands

**GATE:** `node --test cli/test/` passes with new tests. Streaming works.

---

## Phase 3: NextJS Frontend + Integration Surface (T+30 to T+50)

### Team 3A: NextJS Dashboard App
**Worktree:** agent-os (new directory: `web/`)

Tasks:
1. `npx create-next-app@latest web --typescript --tailwind --app`
2. Dashboard page: list running agents + status (polls `/api/v1/agents`)
3. Pipeline page: show stages, progress, proof status (SSE from `/api/v1/pipeline/:id/events`)
4. Audit page: timeline view of audit trail (from `/api/v1/audit/:id`)
5. Contracts page: list + YAML editor with live preview
6. Agent config page: create/configure agents
7. Real-time updates via SSE subscription
8. Auth: Supabase login → token exchange with agent-os

**GATE:** Dashboard shows live agent status. Pipeline progress streams in real-time.

### Team 3B: E2E Integration Testing
**Worktree:** agent-os

Tasks:
1. Start Elixir server + microsandbox + ContextFS
2. Run `agent-os run pipeline --contract research-report --topic "test"` via Node CLI → HTTP → Pipeline → microVM
3. Verify: artifacts produced, audit trail in Mnesia, ContextFS has tagged memories
4. Run `agent-os run pipeline --contract market-dashboard --topic "oil and gas"` → Vercel deploy
5. Verify: live Vercel URL, GitHub repo, proof passing
6. Run second pipeline → verify enriched context from first run (memory scoping works)
7. All 3 paths tested: Node CLI, HTTP API, NextJS dashboard

**GATE:** Full pipeline works end-to-end through all interfaces. Memory scoping verified.

---

## Phase 4: Agent-Hero Marketplace Integration (T+50 to T+65)

### Team 4: Agent-Hero ↔ Agent-OS Bridge
**Worktree:** ~/Documents/Development/agentherowork/agent-hero

Tasks:
1. Add `agent-os` integration module in agent-hero:
   - `app/lib/agent-os-client.ts` — HTTP client for agent-os API
   - `app/api/webhooks/agent-os/route.ts` — webhook receiver for pipeline completion
2. When contract is accepted in agent-hero:
   - Next.js Server Action calls `POST agent-os:4000/api/v1/pipeline/run`
   - Stores `run_id` in Supabase `contracts` table
3. Pipeline progress:
   - Agent-hero subscribes to `GET agent-os:4000/api/v1/pipeline/:run_id/events` (SSE)
   - Bridges events to Supabase Realtime channel
   - Agent-hero dashboard shows live progress
4. Pipeline completion:
   - Agent-os sends webhook to `agent-hero/api/webhooks/agent-os`
   - Webhook updates Supabase: `contracts.status = 'completed'`, stores artifacts
5. Credit flow:
   - Stripe webhook → agent-hero → `POST agent-os:4000/api/v1/escrow/set_balance`
   - Pipeline completion → `agent-os Escrow.settle` → credit to operator
6. Reputation:
   - Pipeline evaluation scores stored in agent-os
   - Agent-hero reads via `GET agent-os:4000/api/v1/agents/:id/reputation`
   - Displayed in marketplace agent profiles

**GATE:** Create a contract in agent-hero → pipeline runs in agent-os → results appear in agent-hero dashboard → credits settle correctly.

---

## Parallel Execution Map

```
T+0:  [Team 1A: Dep flip + merge]  [Team 1B: Dead code + bugs]  [Team 1C: Wire systems]
      │                             │                             │
T+15: └─────────── GATE 1: compile + test ──────────────────────┘
      │
T+15: [Team 2A: Phoenix]  [Team 2B: API hardening]  [Team 2C: CLI upgrade]
      │                    │                          │
T+30: └─────────── GATE 2: compile + test + SSE ───────────────┘
      │
T+30: [Team 3A: NextJS dashboard]  [Team 3B: E2E integration]
      │                             │
T+50: └─────────── GATE 3: full pipeline via all interfaces ──┘
      │
T+50: [Team 4: Agent-Hero integration]
      │
T+65: └─────────── GATE 4: marketplace flow works ───────────┘
```

## Worktree Strategy

Phase 1-3 agents work on: `/Users/mlong/Documents/Development/agentherowork/agent-os`
- Teams within each phase use git worktree isolation to avoid conflicts
- Gate merges happen after all teams in a phase complete

Phase 4 agents work on: `~/Documents/Development/agentherowork/agent-hero`
- Separate repo, separate worktree
- Depends on agent-os server running (started by Phase 3B)

## Communication Protocol

**Slack (#agentos — C0ANJSJG0TG):**
- Phase gate completions with summary of what changed
- Bug fixes with before/after
- Test results

**Telegram (once configured):**
- Agent questions that need human input before proceeding
- Blocking decisions (e.g., "should I delete this module or keep it?")
- Architecture choices that have multiple valid options

## Success Criteria

After Phase 4 completes:
1. agent-os is ONE Elixir app (not 7) with clean module namespaces
2. Node CLI works for all operations
3. NextJS dashboard shows live pipeline progress
4. Agent-hero marketplace triggers agent-os execution
5. Credits flow correctly through the system
6. All tests pass
7. Zero dead code
