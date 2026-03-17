# Chat Dynamics: Inter-Agent Communication for Agent-OS

## Status: Plan

## Problem Statement

Agents in Agent-OS run in total isolation. There is no messaging API between agents, no shared pub/sub, no delegation mechanism, and no way for one agent to discover or communicate with another. The existing `AgentScheduler.Pipeline` provides GenServer-based pub/sub with event types, but agents do not subscribe to it — it was designed for streaming pipeline stages (recon, behavior, load, observer, synthesis) and was never wired to agent execution. The `AgentScheduler.Registry` (Elixir's built-in `Registry` with `:unique` keys) enables O(1) agent lookup by ID, but nothing sends messages between the processes it indexes. `AgentOS.AgentRunner` launches agents via fire-and-forget calls to `agent_module.run_autonomous/2` and only monitors completion and contract verification. Agents cannot ask other agents for help, stream partial results to collaborators, or negotiate task ownership.

The Graph layer has a `:triggers` edge type ("memory causes creation of another") but nothing uses it. Telemetry is one-way observation only. The tool interface (`ToolInterface.Registry`) has no `agent-message` or `agent-delegate` tool.

Erlang/OTP gives us everything we need at the VM level — lightweight processes, `GenServer.call/cast`, `Process.monitor`, `Task.async/await`, `GenStage`, and `Registry` pub/sub dispatch. The work is exposing these primitives through the agent abstraction layer so agents can communicate like OS processes.

---

## Phase 1: Direct Messaging + Delegation

_Minimum viable inter-agent communication. Enables multi-agent workflows where a coordinator agent can assign subtasks to specialist agents and collect results._

### 1.1 Agent Mailbox

**What it does.** Add a message inbox to each agent GenServer process managed by `AgentScheduler.Supervisor`. Each agent accumulates incoming messages in an ordered queue within its GenServer state. Messages are typed structs with sender ID, correlation ID, payload, and timestamp. The agent's `run_autonomous/2` context gains a `receive_messages/1` callback that drains the mailbox.

**Why it matters.** Without a mailbox, there is no destination for inter-agent messages. This is the foundational data structure that every other communication feature builds on. OTP processes already have a mailbox (the process message queue), but we need an application-level abstraction so agents can process messages at their own pace rather than being forced into GenServer callback timing.

**Dependencies.** None. This modifies `AgentScheduler.Agent` (the individual agent GenServer, started by `AgentScheduler.Supervisor.start_agent/1`).

### 1.2 Direct Messaging

**What it does.** Introduce `AgentScheduler.Chat.send/3` — send a message from agent A to agent B by ID. Uses `Registry.lookup(AgentScheduler.Registry, target_id)` to find the target PID, then `GenServer.cast(pid, {:chat_message, msg})` for async delivery or `GenServer.call(pid, {:chat_message, msg}, timeout)` for acknowledged delivery. Messages include a correlation ID for threading.

**Why it matters.** Direct messaging is the most basic communication primitive. A coordinator agent needs to tell a specialist agent what to do and get a result back. Without this, all multi-agent coordination must go through external systems (database polling, HTTP, etc.), which defeats the purpose of running agents as OTP processes on the same BEAM node.

**Dependencies.** Agent Mailbox (1.1). Requires `AgentScheduler.Registry` (already exists — Elixir `Registry` with `:unique` keys, started in `AgentScheduler.start/2`).

### 1.3 Register `agent-message` Tool

**What it does.** Register a new tool in `ToolInterface.Registry` under the `:builtin` tier named `agent-message`. Input schema: `{target_agent_id, message_type, payload}`. The tool's `execute` function calls `AgentScheduler.Chat.send/3`. This allows LLM-driven agents to send messages to other agents as part of their tool-use loop, using the same mechanism they use for web-search or code-exec.

**Why it matters.** Agents interact with the world through tools. If messaging is only available as an Elixir API, only hand-coded agents can use it. Registering it as a tool means any LLM-backed agent can decide to message another agent during its reasoning loop.

**Dependencies.** Direct Messaging (1.2). Requires `ToolInterface.Registry` (already exists).

### 1.4 Delegation Protocol

**What it does.** Introduce `AgentScheduler.Chat.delegate/4` — agent A spawns agent B (via `AgentScheduler.Supervisor.start_agent/1`) to handle a subtask, monitors it with `Process.monitor/1`, and awaits a result message or `:DOWN`. The delegation tracks parent-child relationships in a new `AgentScheduler.Chat.DelegationTracker` GenServer. If the child agent crashes, the parent receives a `{:delegation_failed, child_id, reason}` message in its mailbox. If the child completes, the parent receives `{:delegation_complete, child_id, result}`.

**Why it matters.** Delegation is the multi-agent pattern that matters most for real work. A research agent needs to spawn a web-search agent and a code-analysis agent in parallel, collect their results, and synthesize a report. Without delegation, agents must complete all subtasks themselves, which limits specialization and parallelism. `Task.async` provides the low-level primitive; this wraps it in the agent abstraction with proper lifecycle management through the `DynamicSupervisor`.

**Dependencies.** Agent Mailbox (1.1), Direct Messaging (1.2). Requires `AgentScheduler.Supervisor` (already exists as a `DynamicSupervisor`).

### 1.5 Register `agent-delegate` Tool

**What it does.** Register a new tool in `ToolInterface.Registry` under the `:builtin` tier named `agent-delegate`. Input schema: `{agent_type, subtask, input, timeout_ms}`. The tool's `execute` function calls `AgentScheduler.Chat.delegate/4`, blocks until the child completes or times out, and returns the child's result. The `agent_type` is resolved through `AgentScheduler.Agents.Registry.lookup/1` to find the correct module.

**Why it matters.** Same reasoning as `agent-message` — LLM-driven agents need tool access to delegation. An OpenClaw agent reasoning about a complex task should be able to decide "I need a NemoClaw to handle this subtask" and invoke it through its normal tool-use loop.

**Dependencies.** Delegation Protocol (1.4). Requires `ToolInterface.Registry`, `AgentScheduler.Agents.Registry` (both already exist).

### 1.6 Request/Response Pattern

**What it does.** Introduce `AgentScheduler.Chat.ask/4` — a synchronous request/response wrapper around direct messaging. Agent A sends a message to agent B with a unique request ID and blocks (via `receive` with timeout) until agent B replies with a message carrying the same request ID. Implemented using `GenServer.call/3` semantics internally but at the agent abstraction level, so agents can process the request within their autonomous loop rather than in a GenServer callback.

**Why it matters.** Many inter-agent interactions are naturally request/response: "What is the status of X?", "Analyze this data and return the result", "Do you have capacity for this task?". Fire-and-forget messaging (1.2) requires the sender to manually correlate responses. The ask pattern provides a cleaner API for the common synchronous case while still using the underlying async mailbox.

**Dependencies.** Direct Messaging (1.2), Agent Mailbox (1.1).

---

## Phase 2: Pub/Sub Integration + Discovery + Conversations

_Extends communication beyond point-to-point. Agents can discover each other, subscribe to event streams, and hold structured multi-turn conversations._

### 2.1 Wire Pipeline Pub/Sub to Agents

**What it does.** Enable agents to subscribe to `AgentScheduler.Pipeline` event topics. Add a `subscribe_to_pipeline/2` function to the agent context that calls `AgentScheduler.Pipeline.subscribe/3` with the agent's PID. Pipeline events (`{:pipeline_event, event}`) are automatically routed to the agent's mailbox (1.1). This connects the existing pipeline infrastructure — which already supports publish, subscribe, replay, and crash-recovery cleanup via `Process.monitor` — to the agent execution layer.

**Why it matters.** The Pipeline already implements a robust event bus with stage validation, event logging, replay on crash recovery, and subscriber cleanup on process death. Agents should be able to tap into this infrastructure rather than building a parallel pub/sub system. A monitoring agent could subscribe to `:anomaly_detected` events across all pipelines and react in real time.

**Dependencies.** Agent Mailbox (1.1). Requires `AgentScheduler.Pipeline` (already exists with full pub/sub, event log, and replay support).

### 2.2 Agent Discovery

**What it does.** Introduce `AgentScheduler.Chat.discover/1` — find agents by capability, type, status, or reputation. Queries `AgentScheduler.Supervisor.list_agents/0` for running agents, cross-references with `AgentScheduler.Agents.Registry` for type information, and optionally queries `AgentScheduler.Evaluator.rank_agents/0` for reputation-based filtering. Returns a list of `{agent_id, agent_type, reputation, status}` tuples. Also register an `agent-discover` tool in `ToolInterface.Registry`.

**Why it matters.** Before an agent can message or delegate to another agent, it needs to know which agents exist and what they can do. Hard-coding agent IDs breaks down in dynamic systems where agents are started and stopped on demand. Discovery enables emergent multi-agent coordination: an agent facing a task it cannot handle searches for a specialist and delegates to it.

**Dependencies.** Requires `AgentScheduler.Supervisor`, `AgentScheduler.Agents.Registry`, `AgentScheduler.Evaluator` (all already exist).

### 2.3 Broadcast Channels

**What it does.** Introduce `AgentScheduler.Chat.Channel` — a named topic that agents can join and leave. Uses Elixir's `Registry` in `:duplicate` mode (a second Registry instance, separate from the existing `:unique` `AgentScheduler.Registry`) for O(1) dispatch to all subscribers. `Channel.broadcast(topic, message)` dispatches to all members. `Channel.join(topic)` and `Channel.leave(topic)` manage membership. Channels are lightweight — no GenServer per channel, just Registry entries.

**Why it matters.** Many communication patterns are one-to-many: a coordinator announces task availability, a monitoring agent broadcasts an alert, or agents share status updates. Point-to-point messaging (1.2) requires the sender to know all recipients. Broadcast channels decouple senders from receivers, enabling publish-subscribe patterns that scale independently of the number of participants.

**Dependencies.** Agent Mailbox (1.1).

### 2.4 Conversation Threads

**What it does.** Introduce `AgentScheduler.Chat.Conversation` — a structured multi-turn exchange between two or more agents. Each conversation has an ID, a list of participant agent IDs, and an ordered message history. Messages within a conversation carry the conversation ID and a sequence number. A new `AgentScheduler.Chat.ConversationServer` GenServer manages active conversations, started under `AgentScheduler.Supervisor` (or a dedicated supervisor). Conversations can be forked (branching discussions) and merged (combining conclusions).

**Why it matters.** Real multi-agent collaboration requires context. If agent A asks agent B a question and then asks a follow-up, agent B needs to see the prior exchange. Without conversation threads, every message is context-free, forcing agents to re-explain background on every interaction. Threads also enable audit trails — you can inspect the full dialogue that led to a decision.

**Dependencies.** Direct Messaging (1.2), Agent Mailbox (1.1).

### 2.5 Capability-Based Routing

**What it does.** Extend the agent-message tool to accept a capability descriptor instead of a specific agent ID. The router uses Agent Discovery (2.2) to find agents matching the capability, selects the best candidate by reputation (via `AgentScheduler.Evaluator`), and routes the message. If no matching agent is running, the router can optionally start one via `AgentScheduler.Supervisor.start_agent/1`. This is analogous to service discovery in microservice architectures but within a single BEAM node.

**Why it matters.** Decouples senders from specific agent instances. An agent that needs "web testing" capability should not need to know that `openclaw_tester_42` is the right agent. Capability routing enables dynamic scaling: if the best agent is overloaded, the router picks the next best one.

**Dependencies.** Agent Discovery (2.2), Direct Messaging (1.2). Requires `AgentScheduler.Evaluator` (already exists).

---

## Phase 3: Negotiation + Streaming + External Communication

_Advanced patterns for autonomous multi-agent systems. Agents negotiate task ownership, stream partial results, and communicate with the outside world._

### 3.1 Agent Negotiation

**What it does.** Introduce `AgentScheduler.Chat.Negotiation` — a protocol where agents bid on tasks. The flow: (1) a coordinator broadcasts a task description to a channel, (2) interested agents submit bids (including estimated cost, time, and confidence), (3) the coordinator evaluates bids using `AgentScheduler.Evaluator.distance/3` to compare agent capabilities against task requirements, (4) the coordinator awards the task to the winner via direct message, (5) the winner confirms acceptance. Bids are time-bounded; non-responses are treated as declines.

**Why it matters.** In a system with many specialized agents, centralized assignment is a bottleneck. Negotiation distributes the matching problem: agents self-select based on their own capabilities and current load. This mirrors the PlannerEngine's order book model (demand/supply matching) but at the agent-to-agent level rather than client-to-agent.

**Dependencies.** Broadcast Channels (2.3), Direct Messaging (1.2), Agent Discovery (2.2). Requires `AgentScheduler.Evaluator` (already exists).

### 3.2 Supervision Delegation

**What it does.** Extend the Delegation Protocol (1.4) with full OTP supervision semantics. Parent agents become supervisors of their child agents using `Process.monitor/1` for monitoring and configurable restart strategies (`:one_for_one`, `:one_for_all`). If a child agent crashes and the strategy is `:one_for_one`, the parent re-delegates the subtask. If strategy is `:one_for_all`, the parent cancels all sibling delegations and re-plans. Track the supervision tree in `AgentScheduler.Chat.DelegationTracker` so it can be visualized and debugged. This does NOT replace `AgentScheduler.Supervisor` (the DynamicSupervisor that manages process lifecycle) — it layers application-level supervision logic on top.

**Why it matters.** Delegation without supervision is fragile. If a child agent crashes mid-task, the parent is left waiting forever (or until timeout). OTP already solved this problem for processes; we need the same guarantees at the agent abstraction level. Supervision delegation enables reliable multi-agent pipelines where partial failures are recovered automatically.

**Dependencies.** Delegation Protocol (1.4). Requires `AgentScheduler.Supervisor` (already exists).

### 3.3 Streaming Results via GenStage

**What it does.** Introduce `AgentScheduler.Chat.Stream` — agents produce and consume streaming partial results using GenStage (or Flow for parallel fan-out). A producer agent emits events as it processes data; consumer agents subscribe and process events as they arrive. Back-pressure is handled automatically by GenStage's demand-driven model. This connects naturally to `AgentScheduler.Pipeline` — pipeline stages can be backed by agent GenStage producers/consumers instead of simple message passing.

**Why it matters.** Many agent tasks produce results incrementally: a web scraper finds pages one at a time, a code analyzer processes files sequentially, a research agent gathers sources progressively. Without streaming, the consumer must wait for the producer to finish entirely before starting work. Streaming reduces end-to-end latency from the sum of all stages to the critical path length. The Pipeline module's documentation already cites 40-60% wall-clock time reduction from streaming; GenStage provides the back-pressure guarantees to make this production-ready.

**Dependencies.** Agent Mailbox (1.1), Wire Pipeline Pub/Sub to Agents (2.1). GenStage must be added as a dependency in `mix.exs`.

### 3.4 External Communication

**What it does.** Register tools in `ToolInterface.Registry` for outbound communication: `agent-slack` (send Slack messages via webhook), `agent-webhook` (POST to arbitrary HTTP endpoints), and `agent-email` (send email via SMTP or API). These tools are `:builtin` tier with input validation that prevents SSRF (reusing the existing `validate_url_safety` logic from `ToolInterface.Registry`). Inbound communication is handled by adding webhook endpoints to `AgentOS.Web` (the Phoenix/Plug layer) that route incoming messages to agent mailboxes.

**Why it matters.** Agents that can only talk to each other are limited. Real workflows require agents to notify humans (Slack alert when a test fails), trigger external systems (webhook to CI/CD), and receive external input (customer emails routed to a support agent). External communication turns the agent system from a closed loop into an integration platform.

**Dependencies.** Agent Mailbox (1.1), Direct Messaging (1.2). Requires `ToolInterface.Registry` (already exists). The `AgentOS.Credentials` module handles API keys for Slack/email services.

### 3.5 Consensus Protocol

**What it does.** Introduce `AgentScheduler.Chat.Consensus` — a voting protocol for multi-agent decisions. A proposer agent submits a proposal to a set of voter agents. Each voter returns `{:approve, reason}`, `{:reject, reason}`, or `{:abstain}` within a timeout. The proposer tallies votes against a configurable threshold (e.g., 2/3 majority) and announces the decision. Uses Conversation Threads (2.4) to maintain the deliberation history for audit.

**Why it matters.** Some decisions should not be made unilaterally. When multiple agents have relevant expertise (e.g., "should we deploy this change?"), consensus ensures the decision incorporates diverse perspectives. This is also a safety mechanism: a high-stakes action can require approval from N independent agents before proceeding.

**Dependencies.** Conversation Threads (2.4), Direct Messaging (1.2), Broadcast Channels (2.3).

---

## New Modules Summary

| Module | Type | Phase | Purpose |
|--------|------|-------|---------|
| `AgentScheduler.Chat` | API module | 1 | Top-level API: `send/3`, `ask/4`, `delegate/4`, `discover/1` |
| `AgentScheduler.Chat.DelegationTracker` | GenServer | 1 | Tracks parent-child delegation relationships |
| `AgentScheduler.Chat.Channel` | API module | 2 | Named broadcast channels using `Registry` (`:duplicate`) |
| `AgentScheduler.Chat.Conversation` | Struct | 2 | Conversation thread data structure |
| `AgentScheduler.Chat.ConversationServer` | GenServer | 2 | Manages active conversation threads |
| `AgentScheduler.Chat.Negotiation` | API module | 3 | Bid/counter-bid protocol for task ownership |
| `AgentScheduler.Chat.Stream` | API module | 3 | GenStage-based streaming between agents |
| `AgentScheduler.Chat.Consensus` | API module | 3 | Multi-agent voting protocol |

## New Tools Summary

| Tool Name | Tier | Phase | Input |
|-----------|------|-------|-------|
| `agent-message` | `:builtin` | 1 | `{target_agent_id, message_type, payload}` |
| `agent-delegate` | `:builtin` | 1 | `{agent_type, subtask, input, timeout_ms}` |
| `agent-discover` | `:builtin` | 2 | `{capability?, type?, min_reputation?}` |
| `agent-slack` | `:builtin` | 3 | `{channel, message, thread_ts?}` |
| `agent-webhook` | `:builtin` | 3 | `{url, method, headers, body}` |
| `agent-email` | `:builtin` | 3 | `{to, subject, body, reply_to?}` |

## Existing Modules Modified

| Module | Change | Phase |
|--------|--------|-------|
| `AgentScheduler.Agent` | Add mailbox to GenServer state, handle `:chat_message` casts/calls | 1 |
| `AgentScheduler.Supervisor` | No changes — already supports dynamic agent start/stop | 1 |
| `AgentScheduler.Pipeline` | No changes — agents subscribe using existing `subscribe/3` API | 2 |
| `AgentScheduler.Agents.Registry` | No changes — used by discovery to resolve types | 2 |
| `AgentScheduler.Evaluator` | No changes — used by discovery and negotiation for reputation | 2-3 |
| `ToolInterface.Registry` | Add new tools to `load_builtin_tools/0` | 1-3 |
| `AgentScheduler` (application) | Add `Chat.DelegationTracker`, `Chat.ConversationServer`, channel Registry to supervision tree | 1-2 |

## OTP Primitives Used

| Primitive | Where | Why |
|-----------|-------|-----|
| `GenServer.cast/2` | Direct messaging (async) | Fire-and-forget message delivery |
| `GenServer.call/3` | Request/response pattern | Synchronous ask with timeout |
| `Process.monitor/1` | Delegation, supervision | Detect child agent crash |
| `Task.async/await` | Delegation (parallel subtasks) | Concurrent subtask execution |
| `Registry` (`:unique`) | Agent lookup | Already exists as `AgentScheduler.Registry` |
| `Registry` (`:duplicate`) | Broadcast channels | Multiple agents per topic, O(1) dispatch |
| `GenStage` | Streaming results | Back-pressure-aware producer/consumer |
| `DynamicSupervisor` | Delegation spawning | Already exists as `AgentScheduler.Supervisor` |
| `:telemetry` | All phases | Observable messaging metrics |
