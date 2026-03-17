# AGENTS.md — Agent-OS Elixir Agent Loop

## Agent Loop

Every AI coding agent working on this codebase follows this loop:

```
Dev → Compile → Fix → Write Tests → Test → Notify
```

### Steps

1. **Dev** — Read the task, explore the codebase, write or modify Elixir modules
2. **Compile** — Run `mix compile --warnings-as-errors` from the app directory
3. **Fix** — If compilation fails, fix all errors and warnings, then go to step 2
4. **Write Tests** — Write ExUnit tests for the changes (real OTP processes, no mocks)
5. **Test** — Run `mix test` from the app directory
6. **Notify** — Report results: which files changed, tests passed/failed, warnings

### Rules

- All tests use real OTP processes — no mocks, no stubs, no fakes
- Every GenServer under test must be started and stopped cleanly
- Tests must be deterministic (no `:rand` without seed, no timing-dependent assertions)
- Compile with `--warnings-as-errors` — zero warnings allowed
- Each umbrella app is compiled and tested independently
- Integration tests live in `src/agent_os/test/`

### Umbrella Structure

```
src/
├── agent_os/          # Main orchestrator (depends on all subsystems)
├── agent_scheduler/   # Agent lifecycle, scheduling, pipelines
├── tool_interface/    # 3-tier tool registry, capabilities, sandbox
├── memory_layer/      # ETS + Mnesia typed memory
├── planner_engine/    # Order book, escrow, reputation, market
├── agent_os_web/      # REST API (Plug + Cowboy)
└── agent_os_cli/      # CLI (escript)
```

### Compilation Order

```
memory_layer → tool_interface → agent_scheduler → planner_engine → agent_os → agent_os_web → agent_os_cli
```

### Agent Types

- **OpenClaw** — Full-capability research agent (web_search, browser, filesystem, shell). Default oversight: `:autonomous_escalation`
- **NemoClaw** — NVIDIA-secured agent with restricted tools, privacy routing, policy guardrails. Default oversight: `:supervised`
