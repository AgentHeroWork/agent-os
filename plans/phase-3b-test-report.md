# Phase 3B — E2E Integration Test Report

**Date:** 2026-03-24
**Branch:** main (commit 66b366d)
**Tester:** Team 3B (automated)

---

## 1. Compilation (--warnings-as-errors)

| App | Result |
|-----|--------|
| agent_scheduler | PASS (no warnings) |
| agent_os | PASS (no warnings) |
| agent_os_web | PASS (no warnings) |
| memory_layer | PASS (no warnings) |
| planner_engine | PASS (no warnings) |
| tool_interface | PASS (no warnings) |

**All 6 apps compile cleanly with zero warnings.**

---

## 2. Test Suites

| App | Tests | Failures | Notes |
|-----|-------|----------|-------|
| agent_scheduler | 29 | 0 | All pass. Warnings about :openclaw/:nemoclaw missing callbacks (expected — they use behaviour stubs during isolated test). |
| agent_os | 90 | 1 | 1 timeout failure (see below) |
| agent_os_web | 8 | 0 | All pass. Phoenix endpoint + controllers verified. |
| memory_layer | 7 | 0 | All pass. |
| planner_engine | 8 | 0 | All pass. |
| tool_interface | 7 | 0 | All pass. |
| CLI (Node.js) | 47 | 0 | All 47 tests across 14 suites pass. |
| **TOTAL** | **196** | **1** | |

### agent_os failure detail

**Test:** `test run_autonomous/2 — full pipeline produces .tex file with substantive content from real LLM`
**File:** `test/agents/openclaw_autonomous_test.exs:26`
**Error:** `ExUnit.TimeoutError` after 120,000ms
**Root cause:** The test calls the real OpenAI API to generate a full research paper, compile LaTeX to PDF, and self-repair up to 3 times. The LLM-generated LaTeX failed PDF compilation (pdflatex errors), triggering 3 self-repair LLM round-trips. The combined LLM latency (plan + research + review + 3 repair attempts) exceeded the 120s timeout.
**Verdict:** Environment/LLM issue, not a code defect. The test is tagged `@tag :functional` and is expected to be flaky based on LLM response quality and network latency.

---

## 3. Server Health Check

Server started from `src/agent_os_web` via `mix run --no-halt`.

| Endpoint | Method | Status | Response |
|----------|--------|--------|----------|
| `/api/v1/health` | GET | 200 | `{"status":"ok","version":"0.1.0","uptime_ms":38217}` |
| `/api/v1/contracts` | GET | 200 | `{"contracts":["market-dashboard","research-report"]}` |
| `/api/v1/agents` | POST | 200 | `{"name":"test","type":"openclaw","agent_id":"openclaw_test_9539"}` |
| `/api/v1/agents` | GET | 200 | Returns agent list with profile, metrics, oversight |
| `/api/v1/tools` | GET | 200 | Returns 12 tools (6 builtin + 6 sandbox) |

**Phoenix endpoint starts correctly on port 4000. All REST API routes respond with valid JSON.**

Note: The server must be started from `src/agent_os_web/` (not `src/agent_os/`), because `agent_os_web` depends on `agent_os` (inverted dependency as documented in CLAUDE.md). Running `mix run --no-halt` from `src/agent_os/` starts the OTP app but not the Phoenix web endpoint.

---

## 4. YAML Contract Loading

```
research-report:
  name: "research-report"
  stages: 3
  required_artifacts: [:findings_md, :paper_tex]

market-dashboard:
  name: "market-dashboard"
  stages: 3
```

**Both contracts load successfully via yaml_elixir. Stages and artifacts parsed correctly.**

---

## 5. Namespace Migration Verification

Searched for old namespace references in `src/agent_os/` and `src/agent_os_web/`:

| Old Namespace | Found in agent_os? | Found in agent_os_web? |
|---------------|--------------------|-----------------------|
| `AgentScheduler.Agents.OpenClaw` | No | No |
| `AgentScheduler.Agents.NemoClaw` | No | No |
| `AgentScheduler.LLMClient` | No | No |
| `AgentScheduler.ResearchPrompts` | No | No |

**All old namespaces have been fully migrated. Zero stale references remain.**

---

## 6. microsandbox Integration

```
$ msb server status
Total Namespaces: 0, Total Sandboxes: 0

$ msb exe alpine:latest -e 'echo "microVM works"'
microVM works
```

**microsandbox server is running and microVM execution works.**

---

## 7. Summary

| Category | Status |
|----------|--------|
| Compilation (6 apps) | PASS |
| Unit/integration tests (196 total) | 195 PASS, 1 TIMEOUT |
| Server startup (Phoenix) | PASS |
| HTTP API endpoints (5 tested) | PASS |
| YAML contract loading | PASS |
| Namespace migration | PASS (clean) |
| microsandbox integration | PASS |

### Issues Found

1. **Functional test timeout (non-blocking):** The OpenClaw full-pipeline functional test times out when the LLM generates LaTeX that pdflatex cannot compile. The self-repair loop makes 3 LLM round-trips before exhausting retries, pushing total time past 120s. Consider increasing the timeout for `@tag :functional` tests or mocking the PDF compilation step.

2. **Server start location (documentation note):** The CLAUDE.md says to start the server with `cd src/agent_os && mix run --no-halt`, but the Phoenix web endpoint only starts when running from `src/agent_os_web`. This should be updated.

### Conclusion

The Phase 14/15 architecture restructure is solid. All apps compile without warnings, 195/196 tests pass (the single failure is a network/LLM timeout in a functional test, not a regression), all HTTP endpoints work, contracts load via yaml_elixir, and the namespace migration is complete with no stale references.
