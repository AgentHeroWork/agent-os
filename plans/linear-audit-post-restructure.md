# Linear Audit — Post Architecture Restructure

## Issues to CLOSE (Done — verified in code)

| Issue | Title | Reason |
|-------|-------|--------|
| AOS-15 | MicroVM script not mounted | Fixed: scripts dir mounted as /scripts volume |
| AOS-16 | LLM proxy auth mismatch | Fixed: /api/v1/vm/* routes exempt from auth |
| AOS-17 | CLI crashes displaying artifacts | Fixed: handles both map and array |
| AOS-18 | String.to_existing_atom drops providers | Fixed: explicit pattern matching |
| AOS-19 | Return pipeline run_id | Fixed: Pipeline returns run_id in artifacts |
| AOS-21 | Replace YAML parser | Fixed: yaml_elixir replaces hand-rolled parser |
| AOS-22 | LLM API key validation at startup | Fixed: check_llm_config on start |

## Issues to CLOSE (Won't Do — superseded by restructure)

| Issue | Title | Reason |
|-------|-------|--------|
| AOS-12 | Isolated workspaces per pipeline run | microVM already provides isolation per stage |
| AOS-14 | Symphony interop research | Low priority, deferred indefinitely |

## Issues to KEEP OPEN (still needed)

| Issue | Title | Status |
|-------|-------|--------|
| AOS-1 | Slack notification plugin | Not started |
| AOS-2 | Slack interactive questions | Not started |
| AOS-3 | WhatsApp notifications | Not started |
| AOS-4 | Telegram notifications | Not started |
| AOS-5 | Pluggable notification behaviour | Not started — prerequisite for AOS-1,2,3,4 |
| AOS-6 | Agent escalation routing | Not started |
| AOS-7 | Slack Home Tab dashboard | Not started |
| AOS-8 | Linear GraphQL API client | Not started |
| AOS-9 | Ticket → contract mapping | Not started |
| AOS-10 | Linear poller (Symphony) | Not started |
| AOS-11 | Structured completion messages | Not started |
| AOS-13 | PR creation + review agent | Not started |
| AOS-20 | Streaming/progress for pipelines | SSE endpoint exists (Phase 2A), CLI not yet wired |
| AOS-23 | Secrets management (Vault) | Not started |
| AOS-24 | Short-lived GitHub tokens | Not started |
| AOS-25 | Pre-pipeline credential validation | Not started |

## NEW Issues to Create (found in this audit)

| Title | Priority | Description |
|-------|----------|-------------|
| RunController rejects custom agent types (parse_type whitelist) | High | `parse_type/1` only accepts "openclaw"/"nemoclaw". New agents registered at runtime via Registry are unreachable from API. Fix: add catch-all that converts string to atom and checks Registry. |
| job status always 404 (JobTracker never populated) | High | `AgentScheduler.submit_job` enqueues but never calls `JobTracker.track`. Fix: call `JobTracker.track(job_id, :pending)` in submit_job path. |
| Web contracts page data shape mismatch | Medium | `GET /api/v1/contracts` returns strings but web pages expect objects. Fix: return full contract specs or adjust web pages. |
| agent-runtime.sh hardcodes gpt-4o in 3 places | Medium | Pipeline microVM always sends `model: "gpt-4o"` to LLM proxy. Should read from env var or contract config. |
| CLAUDE.md has wrong server start command | Low | Says `cd src/agent_os && mix run --no-halt` but correct is `cd src/agent_os_web && mix run --no-halt`. |
| Mnesia audit data lost on restart (no disc_copies) | Medium | Audit GenServer creates ram_copies table. Should be disc_copies for persistence. |
| System prompts hardcoded to CERN physics | Medium | research_prompts.ex has CERN physicist persona. Should be generic or contract-configurable. |
| NemoClaw guardrail lists not configurable | Low | PII keywords and approved domains are module attributes. Should come from contract or config. |
