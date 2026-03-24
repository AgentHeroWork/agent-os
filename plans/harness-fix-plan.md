# Harness Fix Plan — From 42% to 78%

## The 4 Gaps

| Gap | Current (42%) | Target (78%) | Files |
|-----|---------------|--------------|-------|
| **1. Agent type whitelist** | `parse_type/1` rejects unknown types with 400 | Any string accepted, Registry lookup, dynamic agents | run_controller.ex, agent_controller.ex |
| **2. Hardcoded model/prompts** | `gpt-4o` in 3 places in agent-runtime.sh, CERN persona in research_prompts.ex | Model from contract/env, generic prompts, per-stage config | agent-runtime.sh, pipeline.ex, contract_spec.ex, YAMLs |
| **3. Tool stubs** | 12 tools return empty results | Remove stubs, microVM tools are real (apk add), document properly | tool_interface/registry.ex |
| **4. Two disconnected paths** | BEAM path skips Pipeline/MicroVM/ContextBridge entirely | BEAM path is thin wrapper, pipeline path is primary | run_controller.ex, agent_runner.ex |

## Parallel Execution

```
T+0 ──── 3 parallel teams ────────────────────────
  │
  Team A: Open the API gate (agent configurability)
    Files: run_controller.ex, agent_controller.ex
    - parse_type accepts any string → Registry lookup
    - agent_profile resolves via Registry
    - resolve_contract accepts contract_name from API body

  Team B: Configurable model + prompts
    Files: agent-runtime.sh, pipeline.ex, contract_spec.ex, YAML contracts
    - agent-runtime.sh reads $LLM_MODEL env var (default from contract)
    - Pipeline.build_env injects model/provider from contract into VM env
    - ContractSpec gets model/provider per-stage fields
    - YAML contracts can specify model: and provider:
    - research_prompts.ex: generic persona (not CERN physicist)

  Team C: Linear audit + cleanup
    Files: none (Linear API only)
    - Close 7 done issues (AOS-15 through AOS-22)
    - Close 2 won't-do issues (AOS-12, AOS-14)
    - Create issues for remaining harness gaps
    - Update project status
  │
T+15 ──── Gate: compile + test ───────────────────
  │
  Verify:
  - POST /api/v1/run with type="custom_agent" → 200 (not 400)
  - agent-runtime.sh uses $LLM_MODEL env var
  - Contract YAML can specify model: anthropic/claude-opus-4-5
  - Linear issues current and accurate
```

## Team A: Open the API Gate

### Fix 1: RunController.parse_type — accept any registered type

```elixir
# BEFORE (whitelist):
defp parse_type("openclaw"), do: {:ok, :open_claw}
defp parse_type("nemoclaw"), do: {:ok, :nemo_claw}
defp parse_type(nil), do: {:error, "missing required field: type"}
defp parse_type(other), do: {:error, "unknown agent type: #{other}"}

# AFTER (Registry lookup):
defp parse_type(nil), do: {:error, "missing required field: type"}
defp parse_type(type_str) when is_binary(type_str) do
  type_atom = String.to_atom(type_str)
  case AgentScheduler.Agents.Registry.lookup(type_atom) do
    {:ok, _module} -> {:ok, type_atom}
    {:error, :not_found} ->
      # Try with underscore variants
      alt = type_str |> String.replace("-", "_") |> String.to_atom()
      case AgentScheduler.Agents.Registry.lookup(alt) do
        {:ok, _module} -> {:ok, alt}
        _ -> {:error, "unknown agent type: #{type_str}. Available: #{available_types()}"}
      end
  end
end

defp available_types do
  AgentScheduler.Agents.Registry.types()
  |> Enum.map(&to_string/1)
  |> Enum.join(", ")
end
```

### Fix 2: AgentController.agent_profile — resolve via Registry

```elixir
# BEFORE (hardcoded):
defp agent_profile(:openclaw), do: AgentOS.Agents.OpenClaw.profile()
defp agent_profile(:nemoclaw), do: AgentOS.Agents.NemoClaw.profile()

# AFTER (Registry):
defp agent_profile(type) do
  case AgentScheduler.Agents.Registry.lookup(type) do
    {:ok, module} -> module.profile()
    {:error, :not_found} -> %{name: to_string(type), capabilities: [], task_domain: [], default_oversight: :autonomous_escalation, description: "Custom agent"}
  end
end
```

### Fix 3: resolve_contract — accept contract name from body

```elixir
# In run_single, allow optional contract_name in body:
contract = case body["contract"] do
  nil -> resolve_contract(type)  # default per type
  name ->
    case AgentOS.Contracts.Loader.load(name) do
      {:ok, spec} -> spec
      _ -> resolve_contract(type)
    end
end
```

## Team B: Configurable Model + Prompts

### Fix 1: agent-runtime.sh — read model from env var

```bash
# BEFORE (3 hardcoded places):
'{messages: [{role: "user", content: $prompt}], model: "gpt-4o", max_tokens: 8192}'

# AFTER:
LLM_MODEL="${LLM_MODEL:-gpt-4o}"
'{messages: [{role: "user", content: $prompt}], model: "'"$LLM_MODEL"'", max_tokens: 8192}'
```

### Fix 2: Pipeline.build_env — inject model from contract

```elixir
# Add to build_env:
base = if stage[:model] || contract.model do
  model = stage[:model] || contract.model || "gpt-4o"
  Map.put(base, "LLM_MODEL", model)
else
  base
end
```

### Fix 3: ContractSpec — add model/provider fields

```elixir
# Add to defstruct:
model: nil,           # default LLM model for all stages
provider: nil,        # default LLM provider

# Each stage can also have model/provider:
# %{name: :researcher, model: "claude-opus-4-5", provider: "anthropic", ...}
```

### Fix 4: YAML contracts — model configurable

```yaml
name: research-report
model: gpt-4o          # default for all stages
provider: openai
stages:
  - name: researcher
    model: claude-opus-4-5    # override per stage
    provider: anthropic
```

### Fix 5: research_prompts.ex — generic persona

Replace CERN physicist with generic research expert that adapts to the topic.
