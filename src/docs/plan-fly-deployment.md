# Fly.io Deployment Plan — Agent-OS

## Current State

Agent-OS deploys to Fly.io as a single machine running the full BEAM. The existing infrastructure:

- **Dockerfile** (`Dockerfile`): Two-stage build using `elixir:1.17-otp-27-slim` builder and `debian:bookworm-slim` runtime. Includes tectonic, git, curl. Sets `RELEASE_NODE=agent_os@127.0.0.1` with `sname` distribution. Mnesia directory at `/data/mnesia`. Health check on port 4000.
- **fly.toml** (`fly.toml`): App `agent-os`, region `iad`, `shared-cpu-1x` / 512MB. Auto-stop/start enabled, min 1 machine. Health check `GET /api/v1/health` every 15s. Mnesia volume mounted at `/data/mnesia`.
- **docker-compose.yml** (`docker-compose.yml`): Single service, port 4000, named volume `mnesia_data`. Passes `AGENT_OS_API_KEY` and `FLY_API_TOKEN` from host environment.
- **AgentOS.Providers.Fly** (`src/agent_os/lib/agent_os/providers/fly.ex`): Manages Fly Machines via `https://api.machines.dev/v1` using `:httpc`. Creates one machine per agent with configurable CPU/memory, health checks, auto-destroy on exit, and on-failure restart (max 3 retries). Internal DNS pattern: `{machine_id}.vm.{app}.internal:4000`.

### What Works

- `fly deploy` deploys agent-os as a single Fly Machine
- Health endpoint responds at `/api/v1/health`
- `AgentOS.Providers.Fly.create_agent/1` can spawn additional Machines via the Machines API
- Agents run within the single BEAM on the deployed machine

### What Is Missing

- Single machine is a single point of failure
- No distributed Erlang between Fly Machines (Dockerfile sets `sname`, not `name`)
- Per-agent Machines are created but cannot communicate back to the main node
- No auto-scaling based on agent workload or contract demand
- No secrets rotation or structured secret management beyond `fly secrets`
- No log aggregation beyond `fly logs`
- No metrics or monitoring dashboard
- Mnesia runs single-node only — no cluster replication
- No CI/CD pipeline — deployment is manual `fly deploy`
- No staging environment, blue-green deployments, or multi-region support

---

## Phase 1: Production-Ready Single Machine

Harden the existing single-machine deployment for production reliability.

### 1.1 Graceful Shutdown Handling

**What it does:** Implement SIGTERM handling in the OTP application so that running agents complete their current step before the BEAM exits. The existing `fly.toml` sets `kill_signal = "SIGTERM"` and `kill_timeout = "30s"`, but the application does not trap exits or drain connections.

**Why it matters:** Without graceful shutdown, agents lose in-progress work on every deploy. Fly sends SIGTERM, waits 30 seconds, then sends SIGKILL. The application needs to use that window.

**Dependencies:** None. Modify `AgentOS.Application` to trap exits and add a shutdown hook.

### 1.2 Secret Management

**What it does:** Move all secrets (`AGENT_OS_API_KEY`, `FLY_API_TOKEN`, LLM provider keys) from environment variables and docker-compose into `fly secrets set`. Document which secrets are required and add a startup check that fails fast if critical secrets are missing.

**Why it matters:** Secrets in docker-compose.yml risk leaking into version control. `fly secrets` encrypts at rest and injects at boot without persisting to disk.

**Dependencies:** None. Uses Fly's built-in `fly secrets` command.

### 1.3 Structured JSON Logging

**What it does:** Configure the Elixir Logger backend to emit structured JSON logs with fields for agent name, agent type, contract ID, and trace ID. Add `fly-log-shipper` as a sidecar or use Fly's built-in log shipping to forward logs to an external sink (Datadog, Grafana Cloud, or S3).

**Why it matters:** `fly logs` is ephemeral and unsearchable. Structured logs enable filtering by agent, correlating failures across contracts, and long-term retention.

**Dependencies:** 1.2 (secrets for log shipping credentials).

### 1.4 CI/CD Pipeline with GitHub Actions

**What it does:** Create a GitHub Actions workflow that runs `mix test` on push, builds the Docker image, and deploys to Fly via `flyctl deploy`. Use a `FLY_API_TOKEN` GitHub secret. Add a staging app (`agent-os-staging`) that deploys on every push to `main`, with production (`agent-os`) deploying only on tagged releases.

**Why it matters:** Manual `fly deploy` is error-prone and requires local tooling. CI/CD ensures every deploy is tested and reproducible.

**Dependencies:** 1.2 (secrets for `FLY_API_TOKEN` in GitHub Actions).

### 1.5 Health Check Hardening

**What it does:** Extend the `/api/v1/health` endpoint to check Mnesia table status, memory usage, and process count. Add a `/api/v1/readiness` endpoint that returns 503 until the application is fully initialized (Mnesia tables loaded, registries started). Update `fly.toml` to use the readiness endpoint for the HTTP check.

**Why it matters:** The current health check only confirms the HTTP server is up. It does not detect a corrupted Mnesia database or an OTP application that started but failed to initialize subsystems.

**Dependencies:** None.

### 1.6 Volume Backup for Mnesia

**What it does:** Add a periodic task (via `:timer.send_interval/2` or a GenServer) that snapshots the Mnesia directory to a Fly volume snapshot or an S3 bucket. Run backups every 6 hours and retain 7 days.

**Why it matters:** The Mnesia volume on Fly is durable but not replicated. Hardware failure or accidental volume deletion would lose all agent state.

**Dependencies:** 1.2 (secrets for S3 credentials if using external backup).

---

## Phase 2: Multi-Machine with Distributed Erlang

Move from a single BEAM to a cluster of Fly Machines that form a distributed Erlang network.

### 2.1 Distributed Erlang via libcluster

**What it does:** Switch the Dockerfile from `RELEASE_DISTRIBUTION=sname` to `RELEASE_DISTRIBUTION=name` with full node names (`agent_os@<fly-private-ip>`). Add `libcluster` with the `Cluster.Strategy.DNSPoll` strategy using Fly's internal DNS (`<app>.internal`). Each machine discovers peers via DNS and forms an Erlang cluster automatically.

**Why it matters:** Distributed Erlang is the foundation for everything in Phase 2. Without it, machines are isolated BEAMs that cannot share state or route messages.

**Dependencies:** Phase 1 complete. Requires updating `fly.toml` to remove `RELEASE_DISTRIBUTION=sname` and set `RELEASE_COOKIE` via `fly secrets`.

### 2.2 Per-Agent Machine Isolation

**What it does:** Extend `AgentOS.Providers.Fly.create_agent/1` to spawn a dedicated Fly Machine for each agent (or agent pool). The spawned machine joins the Erlang cluster via libcluster, registers itself with the agent registry, and accepts work via distributed Erlang messages. The main node acts as the scheduler; worker machines run agent processes.

**Why it matters:** Running all agents on one BEAM means a misbehaving agent (infinite loop, memory leak) can crash the entire system. Per-machine isolation provides OS-level fault boundaries while maintaining Erlang-native communication.

**Dependencies:** 2.1 (distributed Erlang). The existing `create_agent/1` in `AgentOS.Providers.Fly` already creates machines — this feature extends it to join the cluster.

### 2.3 Distributed Agent Registry

**What it does:** Replace or extend the current in-memory agent registry with a distributed registry (using `:pg` process groups or `Horde.Registry`). When an agent registers on a worker machine, it becomes visible to the scheduler on the main node. Agent lookups route transparently across the cluster.

**Why it matters:** The scheduler needs to know which agents are running and where. Without a distributed registry, the main node cannot route contracts to agents on other machines.

**Dependencies:** 2.1 (distributed Erlang).

### 2.4 Mnesia Cluster Replication

**What it does:** Configure Mnesia to replicate tables across cluster nodes. When a new machine joins, it copies tables from an existing node using `Mnesia.add_table_copy/3`. Use `disc_copies` on the primary node and `ram_copies` on worker nodes (or `disc_copies` if the worker has a volume).

**Why it matters:** Single-node Mnesia loses all data if the machine goes down. Replicated Mnesia across the cluster provides high availability for agent state, contract history, and scheduler data.

**Dependencies:** 2.1 (distributed Erlang), 1.6 (volume backup as fallback).

### 2.5 Fly Internal DNS and Flycast Networking

**What it does:** Configure agent-to-agent communication to use Fly's `.internal` DNS and `.flycast` addresses. Each machine exposes port 4000 on the internal network. The scheduler routes requests to `{machine_id}.vm.agent-os.internal:4000`. Add Flycast for internal load balancing across agent pool machines.

**Why it matters:** Fly's internal network is a private WireGuard mesh — no public internet traversal, no TLS overhead for internal calls. This is the networking layer that makes per-agent isolation practical.

**Dependencies:** 2.1 (distributed Erlang), 2.2 (per-agent machines).

### 2.6 Machine Lifecycle Management

**What it does:** Build a `MachineSupervisor` GenServer that monitors spawned Fly Machines. If a machine becomes unhealthy (health check fails 3 times), the supervisor destroys it and spawns a replacement. Track machine state transitions (created -> started -> running -> stopping -> stopped -> destroyed) and emit telemetry events.

**Why it matters:** The current `AgentOS.Providers.Fly` module is stateless — it creates machines but does not track or recover them. Production requires active lifecycle management.

**Dependencies:** 2.2 (per-agent machines).

---

## Phase 3: Multi-Region, Auto-Scaling, and Disaster Recovery

Scale the system across regions and add automated resource management.

### 3.1 Auto-Scaling Based on Job Queue Depth

**What it does:** Monitor the agent scheduler's job queue. When pending jobs exceed a threshold (e.g., 10 per agent type), spawn additional Fly Machines for that agent type. When machines are idle for a configurable duration (e.g., 5 minutes), stop them. Use `fly.toml`'s `auto_stop_machines = "stop"` for HTTP-triggered machines and the Machines API for queue-driven scaling.

**Why it matters:** Fixed machine counts waste money during low demand and bottleneck during spikes. Auto-scaling matches capacity to actual contract demand.

**Dependencies:** 2.2 (per-agent machines), 2.6 (machine lifecycle management).

### 3.2 Multi-Region Agent Deployment

**What it does:** Allow agents to be deployed to specific Fly regions based on where their data sources or users are located. Extend `AgentOS.Providers.Fly.create_agent/1` to accept a `region` parameter. The scheduler considers region affinity when assigning contracts to agents — e.g., a web-scraping agent targeting EU sites runs in `cdg` (Paris) or `ams` (Amsterdam).

**Why it matters:** Latency between an agent and its data source directly impacts execution time. A research agent hitting US APIs from `iad` is 100ms faster per request than from `nrt` (Tokyo).

**Dependencies:** 2.1 (distributed Erlang works cross-region on Fly's private network).

### 3.3 Blue-Green Deployments

**What it does:** Implement zero-downtime deploys by running two versions of the agent-os image simultaneously. New machines boot with the new image and join the cluster. Once healthy, the scheduler drains work from old machines and destroys them. Use Fly Machine metadata to tag machines with their release version.

**Why it matters:** The current `fly deploy` replaces the single machine, causing a brief outage. Blue-green deployments ensure agents are never interrupted mid-contract.

**Dependencies:** 2.1 (distributed Erlang), 2.6 (machine lifecycle management), 1.1 (graceful shutdown).

### 3.4 Cost Management

**What it does:** Add an `IdleReaper` process that periodically lists all Fly Machines via the Machines API and stops any that have been idle (no active agent processes) for more than a configurable threshold. Track machine uptime and cost estimates using Fly's pricing tiers. Emit daily cost reports via structured logging. Consider Fly's `auto_stop_machines = "stop"` for HTTP-idle machines.

**Why it matters:** Per-agent machines can accumulate quickly. A forgotten test deployment of 20 machines at `shared-cpu-1x` / 256MB costs approximately $3/day — manageable, but unmanaged scaling could reach hundreds of machines.

**Dependencies:** 2.6 (machine lifecycle management), 1.3 (structured logging for cost reports).

### 3.5 Metrics and Monitoring

**What it does:** Instrument the BEAM with `telemetry` and expose metrics via a `/metrics` Prometheus endpoint. Track: active agents, machine count by region, job queue depth, contract completion rate, memory per machine, message queue lengths. Deploy Grafana on Fly (or use Grafana Cloud) for dashboards and alerting.

**Why it matters:** You cannot manage what you cannot measure. As the system scales to multiple machines and regions, operators need real-time visibility into cluster health, agent performance, and resource utilization.

**Dependencies:** 1.3 (structured logging), 1.2 (secrets for Grafana Cloud credentials).

### 3.6 Disaster Recovery

**What it does:** Implement cross-region volume replication by running a standby machine in a secondary region (`ord` as backup for `iad`). The standby receives Mnesia replication from the primary. If the primary region goes down, the standby promotes itself and DNS failover routes traffic. Combine with the S3 backups from Phase 1 for belt-and-suspenders recovery.

**Why it matters:** Fly regions can experience outages. A single-region deployment means total downtime during a regional failure. Cross-region standby provides an RTO (Recovery Time Objective) measured in seconds rather than minutes.

**Dependencies:** 2.4 (Mnesia cluster replication), 3.2 (multi-region deployment), 1.6 (volume backups).

---

## Summary

| Phase | Features | Outcome |
|-------|----------|---------|
| **Phase 1** | Graceful shutdown, secrets, JSON logging, CI/CD, health checks, volume backup | Production-safe single machine |
| **Phase 2** | libcluster, per-agent machines, distributed registry, Mnesia replication, Flycast networking, machine lifecycle | Multi-machine Erlang cluster with agent isolation |
| **Phase 3** | Auto-scaling, multi-region, blue-green deploys, cost management, metrics, disaster recovery | Scalable, observable, resilient system |

## Key Files

| File | Role |
|------|------|
| `Dockerfile` | Two-stage build, runtime config, Mnesia volume |
| `fly.toml` | Fly app config, VM size, health checks, volume mounts |
| `docker-compose.yml` | Local development, environment variable passthrough |
| `src/agent_os/lib/agent_os/providers/fly.ex` | Machines API client, agent CRUD, lifecycle operations |

## Key Fly.io Features Used

| Feature | Where Used |
|---------|-----------|
| **Machines API** (`api.machines.dev/v1`) | `AgentOS.Providers.Fly` — create, start, stop, destroy machines |
| **fly secrets** | Phase 1.2 — encrypted secret storage |
| **Volumes** | `fly.toml` mounts — Mnesia persistence |
| **fly-log-shipper** | Phase 1.3 — structured log forwarding |
| **Internal DNS** (`.internal`) | Phase 2.1 — libcluster peer discovery |
| **Flycast** (`.flycast`) | Phase 2.5 — internal load balancing |
| **auto_stop_machines** | `fly.toml` — stop idle HTTP machines |
| **Multi-region** | Phase 3.2 — region-specific agent placement |
