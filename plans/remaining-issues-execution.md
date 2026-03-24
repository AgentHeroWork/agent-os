# Remaining Issues Execution Plan

## 19 Open Issues → 5 Parallel Teams

### Dependency Graph

```
AOS-5 (Notification behaviour) ← prerequisite for:
  ├── AOS-1 (Slack notifications)
  ├── AOS-4 (Telegram notifications)
  ├── AOS-3 (WhatsApp notifications)
  ├── AOS-6 (Escalation routing)
  ├── AOS-11 (Completion messages)
  └── AOS-7 (Slack Home Tab)

AOS-2 (Slack interactive questions) ← depends on AOS-1

AOS-8 (Linear API client) ← prerequisite for:
  ├── AOS-9 (Ticket → contract mapping)
  └── AOS-10 (Linear poller)

AOS-23 (Secrets management) ← prerequisite for:
  ├── AOS-24 (Short-lived GitHub tokens)
  └── AOS-25 (Pre-pipeline credential validation)

AOS-32, 33, 34 (Bugs) ← no dependencies
AOS-13 (PR + review agent) ← no dependencies
AOS-20 (Streaming/progress) ← no dependencies
```

### Parallel Execution

```
T+0 ──── 5 parallel teams ──────────────────────────────

  Team 1: BUG FIXES (AOS-32, 33, 34)                    ~10 min
    Files: audit.ex, run_controller.ex, web/contracts, agent_scheduler.ex

  Team 2: NOTIFICATION SYSTEM (AOS-5, 1, 4, 11, 6)      ~20 min
    Files: new notifications/ module, pipeline.ex hooks

  Team 3: LINEAR INTEGRATION (AOS-8, 9, 10)              ~20 min
    Files: new integrations/ module

  Team 4: SECRETS + SECURITY (AOS-23, 24, 25)            ~15 min
    Files: new secrets/ module, pipeline.ex credential handling

  Team 5: STREAMING + FEATURES (AOS-20, 13, 2)           ~15 min
    Files: cli/run.js SSE, pipeline PR creation

T+20 ──── Gate: compile + test ──────────────────────────

T+20 ──── Team 6: REMAINING (AOS-3, 7)                  ~10 min
  WhatsApp + Slack Home Tab (low priority, depends on Team 2)

T+30 ──── Final gate ───────────────────────────────────
```

---

## Team 1: Bug Fixes (AOS-32, 33, 34)

No dependencies. Quick fixes.

### AOS-32: Mnesia audit disc_copies
**File:** `src/agent_os/lib/agent_os/audit.ex`
Change `ram_copies` to `disc_copies` in the Mnesia table creation. Add `Mnesia.change_table_copy_type` for upgrades.

### AOS-33: Web contracts data shape mismatch
**File:** `src/agent_os_web/lib/agent_os_web/controllers/run_controller.ex`
Change `list_contracts` to return full contract specs instead of just names:
```elixir
def list_contracts(conn, _params) do
  contracts = AgentOS.Contracts.Loader.list()
  |> Enum.map(fn name ->
    case AgentOS.Contracts.Loader.load(name) do
      {:ok, spec} -> %{name: spec.name, description: spec.description,
                        stages: Enum.map(spec.stages, & &1.name),
                        required_artifacts: spec.required_artifacts,
                        model: spec.model, provider: spec.provider}
      _ -> %{name: name}
    end
  end)
  json_resp(conn, 200, %{contracts: contracts})
end
```

### AOS-34: JobTracker never populated
**File:** `src/agent_scheduler/lib/agent_scheduler.ex`
In `submit_job/3`, after `Scheduler.enqueue`, call `AgentOS.JobTracker.track(job_id, :pending)`.
Also in `RunController.run_single` and `run_pipeline`, track the job.

---

## Team 2: Notification System (AOS-5, 1, 4, 11, 6)

### AOS-5: Pluggable notification behaviour
Create `src/agent_os/lib/agent_os/notifications/plugin.ex`:
```elixir
defmodule AgentOS.Notifications.Plugin do
  @callback send_notification(event :: atom(), data :: map(), config :: map()) :: :ok | {:error, term()}
  @callback supports_interactive?() :: boolean()
end
```

Create `src/agent_os/lib/agent_os/notifications/registry.ex` — GenServer holding configured plugins.

Create `src/agent_os/lib/agent_os/notifications/dispatcher.ex`:
```elixir
def dispatch(event, data) do
  Registry.list_plugins()
  |> Enum.each(fn {plugin, config} -> plugin.send_notification(event, data, config) end)
end
```

### AOS-1: Slack notification plugin
Create `src/agent_os/lib/agent_os/notifications/slack.ex`:
- Implements `Plugin` behaviour
- Uses `:httpc` to POST to `https://slack.com/api/chat.postMessage`
- Reads `SLACK_BOT_TOKEN` env var
- Formats messages with Slack Block Kit

### AOS-4: Telegram notification plugin
Create `src/agent_os/lib/agent_os/notifications/telegram.ex`:
- Implements `Plugin` behaviour
- POSTs to `https://api.telegram.org/bot{token}/sendMessage`
- Reads `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` env vars

### AOS-11: Structured completion messages
Wire `Notifications.Dispatcher.dispatch/2` into `Pipeline.run`:
- After pipeline completes: `dispatch(:pipeline_complete, %{contract, topic, artifacts, proof, duration})`
- After pipeline fails: `dispatch(:pipeline_failed, %{contract, topic, stage, error, audit})`

### AOS-6: Agent escalation routing
When `AgentRunner` receives `{:escalate, detail}`:
- Call `Notifications.Dispatcher.dispatch(:escalation, detail)`
- If notification plugin supports interactive, wait for response

---

## Team 3: Linear Integration (AOS-8, 9, 10)

### AOS-8: Linear GraphQL API client
Create `src/agent_os/lib/agent_os/integrations/linear.ex`:
- `list_issues(project, status)` — GraphQL query via `:httpc`
- `get_issue(id)` — fetch issue details
- `update_status(id, status)` — mutation
- `add_comment(id, body)` — mutation
- Uses `LINEAR_API_KEY` env var

### AOS-9: Ticket → contract mapping
Create `src/agent_os/lib/agent_os/integrations/linear_mapper.ex`:
- Read issue title + description + labels
- Map labels to contract names (configurable via app config)
- Extract topic from issue title

### AOS-10: Linear poller
Create `src/agent_os/lib/agent_os/integrations/linear_poller.ex`:
- GenServer with `Process.send_after(self(), :poll, 30_000)`
- On poll: fetch `Todo` issues with `agent-os` label
- For each: map to contract → `Pipeline.run` → update status → add comment with results
- Add to supervision tree

---

## Team 4: Secrets + Security (AOS-23, 24, 25)

### AOS-23: Secrets management
Create `src/agent_os/lib/agent_os/secrets.ex`:
```elixir
defmodule AgentOS.Secrets do
  @callback resolve(atom()) :: {:ok, String.t()} | {:error, term()}
end
```

Create `src/agent_os/lib/agent_os/secrets/env_backend.ex`:
- Reads from System.get_env
- Maps `:github_token` → `GH_TOKEN` or `gh auth token`
- Maps `:vercel_token` → `VERCEL_TOKEN`
- Maps `:openai_api_key` → `OPENAI_API_KEY`

Update `Pipeline.build_env/3` to use `Secrets.resolve/1` instead of direct env reads.

### AOS-25: Pre-pipeline credential validation
In `Pipeline.run/3`, before `execute_stages`:
```elixir
with :ok <- validate_credentials(contract) do
  execute_stages(...)
end
```

### AOS-24: Short-lived GitHub tokens
Document the GitHub App setup flow. Create `src/agent_os/lib/agent_os/secrets/github_app.ex`:
- Generate JWT from App private key
- Create installation token (1hr expiry)
- Used when `GITHUB_APP_ID` + `GITHUB_APP_KEY` are set

---

## Team 5: Streaming + Features (AOS-20, 13, 2)

### AOS-20: Streaming/progress for pipelines
SSE endpoint already exists (`GET /api/v1/events/:run_id`). Wire CLI:

**File:** `cli/src/commands/run.js`
For `runPipeline`, instead of blocking POST:
1. POST to `/api/v1/pipeline/run` (returns immediately with `run_id`)
2. Subscribe to SSE at `/api/v1/events/{run_id}`
3. Display stage progress: `Stage 1/3: researcher... [running]`
4. On `pipeline_complete` event, display artifacts

Note: This requires the server to run pipelines async (return run_id, execute in background). May need `RunController.run_pipeline` to spawn a Task and return immediately.

### AOS-13: PR creation + review agent
Update contract spec to support `deploy_mode: :pr` (instead of pushing to main):
- Agent creates a branch
- Opens a PR with description from pipeline context
- Pipeline returns PR URL in artifacts

### AOS-2: Slack interactive questions
When agent writes `_question.json` to `/shared/output/`:
- Pipeline reads it before next stage
- Posts to Slack via `Notifications.Slack` with interactive buttons
- Waits for response (configurable timeout)
- Writes answer to next stage's `/context/`

---

## Team 6: Low Priority (AOS-3, 7)

### AOS-3: WhatsApp notifications
Same pattern as Telegram — implements `Plugin` behaviour, POSTs to WhatsApp Business API.

### AOS-7: Slack Home Tab
Requires Slack App with Home Tab enabled. Builds Block Kit layout with active pipelines and recent completions. Updates on pipeline events via Slack Events API.

---

## Timeline

```
T+0     Teams 1-5 launch in parallel
T+10    Team 1 done (bug fixes)
T+15    Team 4 done (secrets)
T+15    Team 5 done (streaming)
T+20    Team 2 done (notifications)
T+20    Team 3 done (Linear integration)
T+20    Gate: compile + test
T+20    Team 6 launches (low priority)
T+30    Team 6 done
T+30    Final gate: all 19 issues closed
```

## Files by Team (no conflicts)

| Team | Files Created/Modified |
|------|----------------------|
| 1 | audit.ex, run_controller.ex, web/contracts/page.tsx, agent_scheduler.ex |
| 2 | NEW: notifications/plugin.ex, registry.ex, dispatcher.ex, slack.ex, telegram.ex. MOD: pipeline.ex |
| 3 | NEW: integrations/linear.ex, linear_mapper.ex, linear_poller.ex. MOD: application.ex |
| 4 | NEW: secrets.ex, secrets/env_backend.ex, secrets/github_app.ex. MOD: pipeline.ex build_env |
| 5 | MOD: cli/src/commands/run.js, run_controller.ex (async), contract_spec.ex |
| 6 | NEW: notifications/whatsapp.ex. MOD: Slack app config |

**Conflict risk:** Teams 2 and 4 both modify `pipeline.ex`. Team 2 adds notification dispatch, Team 4 changes `build_env`. Different functions — low risk but need sequencing or careful merge.

**Conflict risk:** Teams 1 and 5 both modify `run_controller.ex`. Team 1 changes `list_contracts`, Team 5 changes `run_pipeline` to async. Different functions — low risk.
