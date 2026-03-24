defmodule AgentOS.AgentRunner do
  @moduledoc """
  Thin monitor for autonomous agent execution.

  The runner does NOT orchestrate agent work. Instead it:
    1. Calls `agent_module.run_autonomous(input, context)`
    2. Validates returned artifacts against the contract
    3. Handles escalation when agents get stuck
    4. Retries on contract verification failure (up to max_retries)

  Agents own their full pipeline. The runner only monitors and validates.
  """

  require Logger

  alias AgentOS.Contracts.{ContractSpec, Verify}

  @doc """
  Run an agent autonomously and validate against a contract.

  Accepts either a module implementing the `Contract` behaviour or a
  `%ContractSpec{}` struct (data-driven contract). Returns `{:ok, artifacts}`
  on success or `{:error, reason}` on failure.
  """
  @spec run(AgentOS.AgentSpec.t(), module() | ContractSpec.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(spec, %ContractSpec{} = contract, job) do
    agent_module = resolve_agent_module(spec.type)
    input = Map.get(job, :input, job)
    max_retries = ContractSpec.max_retries(contract)

    Logger.info("AgentRunner: starting #{spec.name} (#{spec.type}) with contract spec '#{contract.name}'")

    run_with_retries(spec, contract, agent_module, input, max_retries, 0)
  end

  def run(spec, contract, job) when is_atom(contract) do
    agent_module = resolve_agent_module(spec.type)
    input = Map.get(job, :input, job)
    max_retries = contract.max_retries()

    Logger.info("AgentRunner: starting #{spec.name} (#{spec.type}) with contract #{inspect(contract)}")

    run_with_retries(spec, contract, agent_module, input, max_retries, 0)
  end

  defp run_with_retries(_spec, _contract, _agent_module, _input, max_retries, attempt)
       when attempt > max_retries do
    {:error, :max_retries_exceeded}
  end

  defp run_with_retries(spec, contract, agent_module, input, max_retries, attempt) do
    if attempt > 0 do
      Logger.info("AgentRunner: retry attempt #{attempt}/#{max_retries} for #{spec.name}")
    end

    context = build_context(spec, attempt)

    case agent_module.run_autonomous(input, context) do
      {:ok, %{artifacts: artifacts} = result} ->
        validate_and_verify(spec, contract, agent_module, input, max_retries, attempt, artifacts, result)

      {:error, reason} = err ->
        Logger.error("AgentRunner: #{spec.name} failed — #{inspect(reason)}")
        err

      {:escalate, detail} ->
        handle_escalation(spec, contract, agent_module, input, max_retries, attempt, detail)
    end
  end

  defp validate_and_verify(spec, contract, agent_module, input, max_retries, attempt, artifacts, result) do
    required = get_required_artifacts(contract)
    missing = check_required_artifacts(artifacts, required)

    case missing do
      [] ->
        case verify_contract(contract, artifacts) do
          :ok ->
            Logger.info("AgentRunner: #{spec.name} completed successfully")
            {:ok, Map.merge(artifacts, Map.get(result, :metadata, %{}))}

          {:retry, reason} ->
            Logger.warning("AgentRunner: verification failed — #{reason}")
            run_with_retries(spec, contract, agent_module, input, max_retries, attempt + 1)
        end

      missing_list ->
        Logger.warning("AgentRunner: missing artifacts #{inspect(missing_list)} — retrying")
        run_with_retries(spec, contract, agent_module, input, max_retries, attempt + 1)
    end
  end

  defp get_required_artifacts(%ContractSpec{} = spec), do: ContractSpec.required_artifacts(spec)
  defp get_required_artifacts(module) when is_atom(module), do: module.required_artifacts()

  defp verify_contract(%ContractSpec{verify: rules}, artifacts), do: Verify.check(artifacts, rules)
  defp verify_contract(module, artifacts) when is_atom(module), do: module.verify(artifacts)

  defp check_required_artifacts(artifacts, required) do
    Enum.filter(required, fn key ->
      val = Map.get(artifacts, key)
      is_nil(val) or val == "" or val == []
    end)
  end

  defp handle_escalation(spec, contract, agent_module, input, max_retries, attempt, detail) do
    reason = Map.get(detail, :reason, :unknown)
    message = Map.get(detail, :message, "No message")
    Logger.warning("AgentRunner: escalation from #{spec.name} — #{reason}: #{message}")

    # Notify configured channels about escalation
    AgentOS.Notifications.Dispatcher.dispatch(:escalation, detail)

    case reason do
      :compilation_stuck ->
        if attempt < max_retries do
          Logger.info("AgentRunner: asking orchestrator LLM for guidance on compilation issue")
          run_with_retries(spec, contract, agent_module, input, max_retries, attempt + 1)
        else
          Logger.error("AgentRunner: compilation stuck after max retries — failing")
          {:error, {:escalated, :compilation_stuck, message}}
        end

      :infrastructure_failure ->
        Logger.error("AgentRunner: infrastructure failure — #{message}")
        {:error, {:escalated, :infrastructure_failure, message}}

      :guardrail_violation ->
        Logger.error("AgentRunner: guardrail violation — #{message}")
        {:error, {:escalated, :guardrail_violation, message}}

      _ ->
        Logger.error("AgentRunner: unhandled escalation — #{reason}: #{message}")
        {:error, {:escalated, reason, message}}
    end
  end

  defp build_context(spec, attempt) do
    %{
      agent_id: Map.get(spec.metadata, :agent_id, spec.name),
      agent_type: spec.type,
      attempt: attempt,
      output_dir: Map.get(spec.metadata, :output_dir, "/tmp/agent-os/artifacts")
    }
  end

  defp resolve_agent_module(type) do
    case AgentScheduler.Agents.Registry.lookup(type) do
      {:ok, module} -> module
      {:error, :not_found} -> raise "Unknown agent type: #{inspect(type)}. Check AgentScheduler.Agents.Registry."
    end
  end
end
