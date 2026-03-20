# Linear Issues: Agent-OS Features

Project: **agent-os** | Workspace: **Magneton**

Reference: [OpenAI Symphony](https://github.com/openai/symphony) — Elixir/BEAM orchestration framework that polls Linear, creates isolated workspaces, dispatches agents, and requires Proof of Work before merging. Agent-OS follows the same pattern but with microVM isolation (microsandbox) and ContextFS for memory.

---

## Epic: Orchestration Engine Notification & Chat Plugins

The orchestration engine needs bidirectional communication channels — notifications OUT (pipeline status, alerts, proof results) and questions IN (agents can ask humans for input, approval, clarification).

---

### Issue 1: Slack Plugin — Notifications

**Title:** Slack notification plugin for pipeline events
**Priority:** High
**Labels:** feature, notifications, slack

**Description:**
The orchestrator sends notifications to Slack channels for pipeline events:
- Pipeline started (contract name, topic, stages)
- Stage completed (with proof summary: passed/failed)
- Pipeline completed (with artifact URLs, Vercel link, GitHub link)
- Pipeline failed (with error, stage that failed, audit link)
- Escalation events (agent needs human input)

Implementation: Slack Web API via `System.cmd("curl", ...)` or `:httpc` POST to `https://slack.com/api/chat.postMessage`. Uses `SLACK_BOT_TOKEN` env var.

**Acceptance criteria:**
- [ ] Pipeline completion sends message to configured Slack channel
- [ ] Message includes: contract name, stages, artifacts, proof status, duration
- [ ] Failed pipelines send alert with error details
- [ ] Channel configurable per contract (`notifications.slack_channel` in YAML)

---

### Issue 2: Slack Plugin — Interactive Questions

**Title:** Slack interactive questions for agent-to-human communication
**Priority:** High
**Labels:** feature, chat, slack

**Description:**
Agents can ask questions during execution that route to Slack. When an agent escalates or needs clarification, the orchestrator posts a question to Slack and waits for a response. The human replies in-thread, and the response is passed back to the agent.

Flow:
1. Agent writes `_question.json` to `/shared/output/` with `{question, context, options}`
2. Pipeline reads it, posts to Slack with interactive buttons or thread
3. Human replies in Slack thread
4. Pipeline reads reply via Slack API, writes answer to agent's `/context/`
5. Agent continues with the answer

**Acceptance criteria:**
- [ ] Agent can request human input mid-pipeline
- [ ] Question appears in Slack with context
- [ ] Human response flows back to agent
- [ ] Timeout if no response (configurable, default 30 min)

---

### Issue 3: WhatsApp Plugin — Notifications

**Title:** WhatsApp notification plugin via WhatsApp Business API
**Priority:** Medium
**Labels:** feature, notifications, whatsapp

**Description:**
Same notification pattern as Slack but via WhatsApp Business API. Uses template messages for pipeline status updates. Requires `WHATSAPP_TOKEN` and `WHATSAPP_PHONE_ID`.

Implementation: POST to `https://graph.facebook.com/v18.0/{phone_id}/messages`

**Acceptance criteria:**
- [ ] Pipeline completion sends WhatsApp message
- [ ] Uses approved template messages
- [ ] Phone number configurable per contract

---

### Issue 4: Telegram Plugin — Notifications

**Title:** Telegram notification plugin via Bot API
**Priority:** Medium
**Labels:** feature, notifications, telegram

**Description:**
Same notification pattern via Telegram Bot API. Uses `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`.

Implementation: POST to `https://api.telegram.org/bot{token}/sendMessage`

**Acceptance criteria:**
- [ ] Pipeline completion sends Telegram message
- [ ] Supports markdown formatting
- [ ] Chat ID configurable per contract

---

### Issue 5: Notification Plugin Architecture

**Title:** Pluggable notification behaviour for orchestration engine
**Priority:** High
**Labels:** feature, architecture, notifications

**Description:**
Define an Elixir behaviour `AgentOS.Notifications.Plugin` that all notification plugins implement:

```elixir
@callback send_notification(event :: atom(), data :: map(), config :: map()) :: :ok | {:error, term()}
@callback supports_interactive?() :: boolean()
@callback send_question(question :: map(), config :: map()) :: {:ok, response :: String.t()} | {:error, term()}
```

Plugins registered in a `Notifications.Registry` GenServer. The contract declares which notification channels to use:

```yaml
notifications:
  slack:
    channel: "#agenthero"
    events: [pipeline_complete, pipeline_fail, escalation]
  telegram:
    chat_id: "123456"
    events: [pipeline_complete]
```

The Pipeline module calls `Notifications.dispatch(event, data)` which fans out to all configured plugins.

**Acceptance criteria:**
- [ ] Behaviour defined with send_notification and send_question callbacks
- [ ] Registry holds configured plugins per pipeline
- [ ] Contract YAML declares notification config
- [ ] Pipeline dispatches events to all configured plugins

---

### Issue 6: Agent Escalation via Chat

**Title:** Agent escalation routing to chat channels
**Priority:** High
**Labels:** feature, chat, escalation

**Description:**
When an agent escalates (proof fails, tool missing, ambiguous instructions), the orchestrator routes the escalation to the configured chat channel. The human can:
- Provide guidance (text reply → injected into agent context)
- Approve/reject (button → pipeline continues or stops)
- Skip stage (button → pipeline moves to next stage)

This connects the existing `AgentType.autonomous_result` `:escalate` return with real notification channels.

**Acceptance criteria:**
- [ ] Escalation posts to Slack/Telegram/WhatsApp with context
- [ ] Human can reply with guidance
- [ ] Reply is injected into agent's next context
- [ ] Timeout falls back to contract's escalation policy

---

### Issue 7: Pipeline Status Dashboard (Slack Home Tab)

**Title:** Real-time pipeline status in Slack Home Tab
**Priority:** Low
**Labels:** feature, slack, dashboard

**Description:**
A Slack App Home Tab showing active pipelines, recent completions, and proof status. Updates in real-time using Slack's Events API + Home Tab blocks.

**Acceptance criteria:**
- [ ] Slack Home Tab shows active pipelines
- [ ] Completed pipelines show proof status and artifact links
- [ ] Auto-updates on pipeline events

---

## Epic: Linear Plugin — Planning Engine Integration

Inspired by [OpenAI Symphony](https://github.com/openai/symphony) which polls Linear boards and dispatches agents per ticket. Agent-OS should do the same.

---

### Issue 8: Linear API Client (Elixir)

**Title:** Elixir client for Linear GraphQL API
**Priority:** High
**Labels:** feature, linear, planning

**Description:**
An Elixir module `AgentOS.Integrations.Linear` that wraps the Linear GraphQL API via `:httpc`. Operations:
- List issues by project/team/status
- Get issue details (description, labels, assignee, priority)
- Update issue status (In Progress, Done, Cancelled)
- Create comments on issues
- Create issues programmatically

Uses `LINEAR_API_KEY` env var for auth. POST to `https://api.linear.app/graphql`.

**Acceptance criteria:**
- [ ] List issues from a Linear project
- [ ] Read issue details (title, description, labels)
- [ ] Update issue status
- [ ] Post comments with pipeline results

---

### Issue 9: Linear Ticket → Contract Mapping

**Title:** Map Linear tickets to agent contracts automatically
**Priority:** High
**Labels:** feature, linear, contracts

**Description:**
When a Linear ticket is labeled with `agent-os` or assigned to the Agent-OS bot, the planning engine:
1. Reads the ticket title + description
2. Matches to a contract template (research-report, market-dashboard, or custom)
3. Extracts the topic/task from the ticket description
4. Creates a pipeline run with the matched contract

Labels drive contract selection:
- `research` → research-report contract
- `dashboard` → market-dashboard contract
- `custom` → reads contract YAML from ticket description code block

**Acceptance criteria:**
- [ ] Linear ticket with `agent-os` label triggers pipeline
- [ ] Contract type inferred from ticket labels
- [ ] Topic extracted from ticket title/description
- [ ] Pipeline results posted back as Linear comment

---

### Issue 10: Linear Poller — Autonomous Issue Processing

**Title:** Background poller that watches Linear for new agent-os tickets
**Priority:** High
**Labels:** feature, linear, automation, symphony-inspired

**Description:**
A GenServer `AgentOS.Integrations.LinearPoller` that:
1. Polls Linear every N seconds (configurable, default 30s) for issues labeled `agent-os` in `Todo` status
2. For each new issue: maps to contract → creates pipeline run → moves to `In Progress`
3. On pipeline completion: posts results as comment → moves to `Done` (or `Review` if proof partially failed)
4. On pipeline failure: posts error + audit trail as comment → moves to `Cancelled` or keeps in `In Progress`

This is the Symphony pattern: Linear tickets automatically become autonomous implementation runs.

**Acceptance criteria:**
- [ ] Poller detects new `agent-os` labeled tickets
- [ ] Automatically starts pipeline for each ticket
- [ ] Posts results (artifacts, Vercel URL, proof status) as ticket comment
- [ ] Updates ticket status throughout lifecycle
- [ ] Handles concurrent tickets (multiple pipelines in parallel)

---

### Issue 11: Pipeline Completion Messages

**Title:** Structured completion messages to all configured channels
**Priority:** High
**Labels:** feature, notifications, completion

**Description:**
When a pipeline completes (success or failure), the orchestrator sends a structured completion message to ALL configured notification channels. The message includes:

For success:
- Contract name and topic
- Duration and stage count
- Artifact links (Vercel URL, GitHub repo)
- Proof-of-work summary (all checks passed / N of M passed)
- Audit summary (commands executed, LLM calls, tools installed)
- Link to full audit trail API endpoint

For failure:
- Contract name and topic
- Stage that failed and error reason
- Partial artifacts produced
- Audit trail up to failure point
- Suggested action (retry, fix contract, check credentials)

**Acceptance criteria:**
- [ ] Success message sent to Slack/Telegram/WhatsApp with artifact links
- [ ] Failure message sent with error details and audit
- [ ] Message format is channel-appropriate (Slack blocks, Telegram markdown, WhatsApp template)
- [ ] Linear ticket updated with same information

---

## Epic: Symphony-Inspired Features

Features inspired by [OpenAI Symphony](https://github.com/openai/symphony) adapted for Agent-OS.

---

### Issue 12: Isolated Workspaces per Pipeline Run

**Title:** Each pipeline run gets a fully isolated workspace
**Priority:** Medium
**Labels:** feature, isolation, symphony-inspired

**Description:**
Symphony creates isolated git worktrees per implementation run. Agent-OS already has microVM isolation but should also:
- Create a unique workspace directory per pipeline run
- Clone relevant repos into the workspace
- Mount workspace into microVMs
- Clean up workspace after completion (configurable retention)

**Acceptance criteria:**
- [ ] Each pipeline run gets a unique workspace ID
- [ ] Workspace survives stage transitions (shared across stages)
- [ ] Workspace cleaned up after configurable retention period

---

### Issue 13: PR Creation + Review Agent

**Title:** Agents create PRs and self-review before human merge
**Priority:** Medium
**Labels:** feature, github, symphony-inspired

**Description:**
For code-producing contracts, the deployer stage should:
1. Create a branch (not push to main)
2. Open a PR with description generated from pipeline context
3. A review agent runs as an additional stage to review the PR
4. Only merge after proof-of-work passes + review agent approves
5. Post PR link to notification channels

**Acceptance criteria:**
- [ ] Deployer creates PR instead of pushing to main
- [ ] PR description includes pipeline context and proof status
- [ ] Review agent can approve/request changes
- [ ] Merge requires proof + review approval

---

### Issue 14: Agent-OS ↔ Symphony Interop

**Title:** Research interoperability between Agent-OS and OpenAI Symphony
**Priority:** Low
**Labels:** research, symphony

**Description:**
Both Agent-OS and Symphony are Elixir/BEAM. Investigate:
- Can Agent-OS contracts be expressed as Symphony "runs"?
- Can Symphony dispatch to Agent-OS microVMs instead of Codex?
- Can Agent-OS use Symphony's Linear polling infrastructure?
- Shared OTP patterns: both use GenServers, supervisors, similar lifecycle models
