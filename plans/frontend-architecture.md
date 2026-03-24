# Frontend Architecture: Two Apps

## The Two Frontends

### 1. agent-os-web — Local Operator Dashboard

**What it is:** A lightweight Next.js app that connects to YOUR local agent-os server. Like Docker Desktop but for AI agents. Shows what's running on your machine.

**Lives in:** `agent-os` monorepo as `web/` directory

**Connects to:** `localhost:4000` (your local Elixir server)

**Users:** Individual developers/operators running agent-os locally

**Features:**
- Dashboard: running agents, active pipelines, recent completions
- Pipeline viewer: real-time stage progress via SSE
- Audit trail: timeline of every command, LLM call, tool use
- Contract editor: YAML with live preview + validation
- Agent config: create/configure agents, set oversight mode
- Memory browser: search ContextFS + Mnesia memories
- MicroVM monitor: active sandboxes, resource usage
- Proof viewer: per-stage proof-of-work results
- Logs: real-time streaming from running agents

**Tech:** Next.js 15, Tailwind, SSE for real-time, direct API calls to localhost:4000

**Auth:** None needed (local machine) or simple shared key from `AGENT_OS_API_KEY`

---

### 2. agent-hero — Marketplace Platform + Admin Console

**What it is:** The existing Next.js marketplace where clients hire agent teams. Needs an admin console added for platform operations.

**Lives in:** `~/Documents/Development/agentherowork/agent-hero` (separate repo)

**Connects to:** Supabase (marketplace data) + agent-os API (execution engine, possibly remote)

**Users:**
- Clients: post jobs, review proposals, track contract progress
- Operators: register agents, bid on jobs, manage earnings
- Admins: system overview, user management, billing, cloud spend

**Existing features (marketplace):**
- Job posting + proposal system
- Contract lifecycle (Supabase)
- Agent profiles + deployment
- Credit/billing via Stripe

**New features needed (admin console):**
- System overview: all running agents across all operators
- Cloud spend dashboard: Fly.io costs, LLM token usage, storage
- User management: operators, clients, permissions
- Agent fleet view: all registered agents, health, reputation scores
- Pipeline monitor: all active pipelines across the platform
- Revenue dashboard: platform fees, operator payouts, escrow status
- Audit log: platform-wide audit trail
- Configuration: system settings, rate limits, feature flags

**Tech:** Next.js 15, Supabase, Stripe, Vercel AI SDK, Server Actions

**Auth:** Supabase Auth with role-based access (client/operator/admin)

---

## How They Relate

```
Developer's Machine                          Cloud (Vercel + Fly.io)
──────────────────                          ──────────────────────

agent-os-web (localhost:3000)               agent-hero (agenthero.work)
  │                                           │
  ├── Shows YOUR local agents                 ├── Marketplace: jobs, proposals
  ├── YOUR pipeline progress                  ├── Contract management
  ├── YOUR audit trails                       ├── Admin console
  └── Connects to ↓                           └── Connects to ↓
                                                    │
agent-os server (localhost:4000)             agent-os server (Fly.io)
  │                                           │
  ├── Runs YOUR agents locally                ├── Runs marketplace agents
  ├── microsandbox VMs                        ├── Fly Machines per agent
  └── Mnesia + ContextFS                      └── Distributed Mnesia
```

**agent-os-web** is the LOCAL view — what's happening on my machine.
**agent-hero** is the PLATFORM view — what's happening across all users.

Both talk to agent-os servers, but:
- agent-os-web talks to localhost (direct, no auth needed)
- agent-hero talks to a remote agent-os via HTTP (auth via Supabase JWT → agent-os token exchange)

---

## Build Plan

### Phase 3A: agent-os-web (local dashboard)

```
web/
├── app/
│   ├── page.tsx                 # Dashboard: agent count, active pipelines, recent runs
│   ├── agents/
│   │   ├── page.tsx             # Agent list with status, type, oversight
│   │   └── [id]/page.tsx        # Agent detail: logs, metrics, job history
│   ├── pipelines/
│   │   ├── page.tsx             # Active + recent pipelines
│   │   └── [id]/page.tsx        # Pipeline detail: stage progress (SSE), proof, audit
│   ├── contracts/
│   │   ├── page.tsx             # Contract list
│   │   └── editor/page.tsx      # YAML editor with live preview
│   ├── audit/
│   │   └── [id]/page.tsx        # Audit trail timeline
│   └── layout.tsx               # Sidebar nav + status bar
├── lib/
│   ├── api.ts                   # HTTP client for agent-os API
│   ├── sse.ts                   # SSE client for pipeline events
│   └── types.ts                 # TypeScript types matching Elixir structs
└── package.json
```

**API endpoints already available:**
- `GET /api/v1/health` → status bar
- `GET /api/v1/agents` → agent list (paginated)
- `GET /api/v1/agents/:id` → agent detail
- `POST /api/v1/run` → trigger single agent
- `POST /api/v1/pipeline/run` → trigger pipeline
- `GET /api/v1/contracts` → contract list
- `GET /api/v1/audit/:id` → audit trail
- `GET /api/v1/audit/:id/:stage/proof` → proof report
- `GET /api/v1/events/:run_id` → SSE pipeline events (new, from Phase 2A)
- `GET /api/v1/tools` → tool registry

**Missing endpoints (need to add):**
- `GET /api/v1/pipelines` → list active/recent pipelines
- `GET /api/v1/pipelines/:id` → pipeline status + artifacts
- `GET /api/v1/memory/search?q=...` → search memories (controller exists but may not work)

### Phase 4: agent-hero admin console

**New routes in existing agent-hero app:**

```
app/(admin)/
├── layout.tsx                   # Admin sidebar (separate from marketplace)
├── page.tsx                     # System overview dashboard
├── agents/page.tsx              # All agents across all operators
├── pipelines/page.tsx           # All active pipelines platform-wide
├── users/page.tsx               # User management (operators + clients)
├── billing/page.tsx             # Revenue, payouts, escrow status
├── spend/page.tsx               # Cloud costs (Fly.io, LLM tokens)
├── audit/page.tsx               # Platform audit log
└── settings/page.tsx            # System config, rate limits, features
```

**Data sources:**
- Supabase: users, contracts, agents, billing
- agent-os API: running agents, pipeline status, audit trails
- Stripe: revenue, payouts
- Fly.io API: machine costs, resource usage
- LLM provider dashboards: token consumption (or tracked via agent-os Audit)

**Auth:** Admin role check via Supabase RLS. Only users with `role: 'admin'` see the admin routes.

---

## Shared Components

Both apps need similar UI components. Create a shared package:

```
packages/
└── @agent-hero/ui/
    ├── AgentCard.tsx           # Agent status card
    ├── PipelineProgress.tsx    # Stage-by-stage progress bar
    ├── AuditTimeline.tsx       # Audit entry timeline
    ├── ProofBadge.tsx          # Pass/fail proof indicator
    ├── ContractViewer.tsx      # YAML contract display
    └── StatusIndicator.tsx     # Health/running/stopped states
```

Or use a Tailwind-based design system and copy patterns (simpler for now).

---

## Execution Order

```
Phase 3A: agent-os-web (local dashboard)     ← builds in agent-os repo
  - Scaffold Next.js app in web/
  - Dashboard, agents, pipelines pages
  - SSE integration for real-time progress
  - Contract editor
  - Audit trail viewer

Phase 4A: agent-hero admin console            ← builds in agent-hero repo
  - Add admin routes to existing app
  - System overview dashboard
  - User management
  - Billing/revenue dashboard
  - Connect to agent-os API for live data

Phase 4B: agent-hero ↔ agent-os bridge       ← both repos
  - contract.accepted triggers agent-os pipeline
  - SSE progress bridged to Supabase Realtime
  - Completion webhook updates Supabase
  - Credit flow: Stripe → agent-hero → agent-os Escrow
```
