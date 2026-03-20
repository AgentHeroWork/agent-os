# BUILD PLAN: Proof of Work + Audit Logging + Self-Installing Agents

## The Problems

### 1. No Proof of Work
Agents write files and say "done." Nobody verifies the output works. A dashboard HTML could be broken. A JSON file could be invalid. A Vercel deploy could fail silently. The contract says `required_artifacts: [findings_md]` but only checks the file exists — not that it's correct.

### 2. Agents Don't Install Their Own Tools
The agent-runtime fails when tools are missing (gh, rsync). The LLM tries to use `gh` without installing it first. The contract should tell the agent: "install whatever you need to complete the task."

### 3. No Audit Trail
When an agent runs 6 commands inside a microVM, the orchestrator has no record of what happened. No log of which tools were used, which commands succeeded/failed, how long each took, or what the LLM decided. If something goes wrong, there's no forensics.

---

## Architecture

### Proof of Work

Every contract stage has implicit and explicit verification:

```yaml
# Contract declares explicit proof requirements
stages:
  - name: researcher
    instructions: "..."
    proof:
      - validate_json: market-data.json
      - validate_json: news.json
      - min_items: market-data.json: 5
      - min_items: news.json: 5
      - min_bytes: findings.md: 500

  - name: developer
    proof:
      - validate_html: app/index.html
      - min_bytes: app/index.html: 1000
      - contains: app/index.html: "chart.js"

  - name: deployer
    proof:
      - url_responds: deploy_url.txt
      - url_responds: repo_url.txt
```

The agent-runtime runs proof checks AFTER completing its work. If proof fails, it tells the LLM what failed and the LLM fixes it (self-repair loop). The proof report is written to `/shared/output/_proof.json`:

```json
{
  "stage": "researcher",
  "checks": [
    {"check": "validate_json", "file": "market-data.json", "passed": true},
    {"check": "min_items", "file": "news.json", "expected": 5, "actual": 8, "passed": true},
    {"check": "min_bytes", "file": "findings.md", "expected": 500, "actual": 1082, "passed": true}
  ],
  "all_passed": true,
  "tools_installed": ["curl", "jq", "git", "nodejs", "npm"],
  "tools_used": ["python3", "cat", "mkdir"],
  "commands_executed": 3,
  "commands_failed": 0,
  "llm_calls": 1,
  "duration_seconds": 45
}
```

### Self-Installing Tools

The agent-runtime prompt tells the LLM:

```
You are running in Alpine Linux. You can install ANY tool you need using:
  apk add <package>

Common packages: curl, jq, git, nodejs, npm, python3, github-cli, bash
Install tools FIRST before using them.
```

The contract can also declare required tools:

```yaml
stages:
  - name: deployer
    tools: [github-cli, nodejs, npm]  # runtime installs these before LLM plans
```

### Audit Logging (Elixir-side)

Every agent action is logged through the Elixir orchestrator. Two layers:

**Layer 1: Agent-side audit** — the agent-runtime writes `_audit.json` to `/shared/output/` with every command executed, every tool used, every LLM call made.

**Layer 2: Orchestrator-side audit** — the Pipeline module logs every stage start/complete/fail, every ContextFS call, every MicroVM lifecycle event to a structured Elixir Logger + Mnesia audit table.

```elixir
defmodule AgentOS.Audit do
  # Structured audit logger backed by Mnesia + Elixir Logger

  def log_stage_start(pipeline_id, stage, contract)
  def log_stage_complete(pipeline_id, stage, proof, duration_ms)
  def log_stage_fail(pipeline_id, stage, reason, audit_data)
  def log_tool_use(pipeline_id, stage, tool, command, exit_code, duration_ms)
  def log_llm_call(pipeline_id, stage, model, tokens_in, tokens_out, duration_ms)
  def log_contextfs_call(pipeline_id, stage, operation, tags, duration_ms)

  def get_audit_trail(pipeline_id) :: [audit_entry()]
  def get_stage_proof(pipeline_id, stage) :: proof_report()
end
```

Backed by Mnesia table `:audit_log` with indexes on `pipeline_id`, `stage`, `timestamp`.

The Pipeline module calls Audit at every step:

```elixir
def run_stage(stage, state, contract, ...) do
  Audit.log_stage_start(state.run_id, stage.name, contract.name)

  case MicroVM.run_agent(...) do
    {:ok, output} ->
      # Read proof and audit from agent output
      proof = read_proof(output_dir)
      audit = read_audit(output_dir)

      Audit.log_stage_complete(state.run_id, stage.name, proof, elapsed_ms)
      log_agent_audit_entries(state.run_id, stage.name, audit)

      if proof_passed?(proof) do
        {:ok, new_state}
      else
        {:error, {:proof_failed, proof}}
      end

    {:error, reason} ->
      Audit.log_stage_fail(state.run_id, stage.name, reason, %{})
      {:error, reason}
  end
end
```

---

## Build Phases

### Phase A: Agent-Runtime Proof of Work + Tool Installation

**What changes in agent-runtime.sh:**

1. Add tool installation step BEFORE planning:
   - Read `tools` from brief if declared
   - Always install base tools: `curl jq bash`
   - LLM prompt includes: "Install any additional tools you need with apk add"

2. Add proof-of-work step AFTER execution:
   - Parse proof requirements from brief
   - Run validation checks (validate_json, validate_html, min_bytes, min_items, url_responds)
   - If proof fails → send failures to LLM → LLM fixes → re-check (max 3 attempts)
   - Write `_proof.json` to /shared/output/

3. Add audit logging throughout:
   - Log every command executed (command, exit_code, duration, stdout_bytes)
   - Log every LLM call (prompt_bytes, response_bytes, duration)
   - Log every tool installed
   - Write `_audit.json` to /shared/output/

**VALIDATE:**
- [ ] Agent installs github-cli when deployer stage needs it
- [ ] Proof checks catch invalid JSON
- [ ] Proof checks catch missing files
- [ ] Failed proof triggers LLM self-repair
- [ ] _proof.json and _audit.json written to output

### Phase B: Elixir Audit Module

**New module: `AgentOS.Audit`**

GenServer backed by Mnesia table `:audit_log`. Fields:
- `id` (unique)
- `pipeline_id`
- `stage`
- `event` (stage_start, stage_complete, stage_fail, tool_use, llm_call, contextfs_call, proof_check)
- `data` (map with event-specific fields)
- `timestamp`

**Wire into Pipeline.run_stage:**
- log_stage_start before MicroVM.run_agent
- Read _proof.json and _audit.json from output after completion
- log_stage_complete with proof report
- log each agent-side audit entry as tool_use events
- log_stage_fail on error

**New HTTP endpoint:**
- `GET /api/v1/audit/:pipeline_id` → returns full audit trail
- `GET /api/v1/audit/:pipeline_id/:stage/proof` → returns proof report

**VALIDATE:**
- [ ] Audit entries in Mnesia after pipeline run
- [ ] GET /api/v1/audit/:id returns structured trail
- [ ] Proof report accessible via API

### Phase C: Contract Proof Declarations

**Update ContractSpec to include proof field per stage:**

```elixir
%{
  name: :researcher,
  instructions: "...",
  proof: [
    {:validate_json, "market-data.json"},
    {:min_items, "market-data.json", 5},
    {:min_bytes, "findings.md", 500}
  ]
}
```

**Update YAML parser to handle proof section.**

**Update ContextBridge.prepare_context to include proof requirements in brief.md.**

**VALIDATE:**
- [ ] ContractSpec.from_map parses proof field
- [ ] Brief.md includes proof requirements for the agent
- [ ] Agent-runtime reads proof requirements and validates

### Phase D: Re-run Oil & Gas with Proof of Work

Full pipeline with all fixes:
- Deployer installs github-cli (`apk add github-cli`)
- Each stage writes _proof.json verifying its output
- Each stage writes _audit.json with command log
- Pipeline reads proof, fails if checks don't pass
- Audit trail stored in Mnesia
- Vercel URL captured and verified (url_responds check)
- GitHub repo created successfully

**VALIDATE (FINAL):**
- [ ] All 3 stages complete with proof passing
- [ ] Vercel dashboard live and verified
- [ ] GitHub repo exists with all artifacts
- [ ] Audit trail in Mnesia shows every command, tool, LLM call
- [ ] GET /api/v1/audit/:id returns full trail
- [ ] Slack notification to #agenthero

---

## Execution Order

```
Phase A: agent-runtime.sh (tool install + proof + audit)     [first]
Phase B: AgentOS.Audit module (Elixir/Mnesia)               [parallel with A]
Phase C: ContractSpec proof declarations                      [after A]
Phase D: Full pipeline re-run with proof                      [after all]
```
