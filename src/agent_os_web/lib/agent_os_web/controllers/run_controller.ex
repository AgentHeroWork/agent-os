defmodule AgentOS.Web.Controllers.RunController do
  @moduledoc """
  REST controller for agent execution and pipeline runs.

  Provides endpoints to run a single agent, execute a multi-stage pipeline,
  and list available contracts. All calls to AgentOS core modules use direct
  function calls since :agent_os_web depends on :agent_os.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  # ── POST /api/v1/run ─────────────────────────────────────────────

  @doc """
  Runs a single agent with a resolved contract.

  Expects JSON body with `type`, `topic`, and optional `model`, `provider`.
  Builds an AgentSpec, resolves the contract, and delegates to AgentRunner.
  """
  @spec run_single(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def run_single(conn, _params) do
    body = conn.body_params

    with {:ok, type} <- parse_type(body["type"]),
         {:ok, topic} <- require_param(body, "topic") do
      agent_id = "api_#{:erlang.unique_integer([:positive])}"

      spec = %AgentOS.AgentSpec{
        type: type,
        name: "api_#{:erlang.unique_integer([:positive])}",
        oversight: :autonomous_escalation,
        metadata: %{agent_id: agent_id, output_dir: "/tmp/agent-os/artifacts"}
      }

      spec =
        spec
        |> maybe_set_model(body["model"])
        |> maybe_set_provider(body["provider"])

      contract = case body["contract"] do
        nil -> resolve_contract(type)
        name ->
          case AgentOS.Contracts.Loader.load(name) do
            {:ok, contract_spec} -> contract_spec
            _ -> resolve_contract(type)
          end
      end
      input = %{input: %{topic: topic}}

      # Track job for status queries
      try do
        AgentOS.JobTracker.track(agent_id, :running)
      catch
        _, _ -> :ok
      end

      case AgentOS.AgentRunner.run(spec, contract, input) do
        {:ok, artifacts} ->
          json_resp(conn, 200, %{artifacts: artifacts})

        {:error, reason} ->
          json_resp(conn, 500, %{error: "run_failed", detail: inspect(reason)})
      end
    else
      {:error, msg} ->
        json_resp(conn, 400, %{error: msg})
    end
  end

  # ── POST /api/v1/pipeline/run ────────────────────────────────────

  @doc """
  Runs a multi-stage pipeline from a named contract.

  Expects JSON body with `contract` (name), `topic`, and optional `env`.
  Loads the contract spec from priv/contracts/ and delegates to Pipeline.
  """
  @spec run_pipeline(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def run_pipeline(conn, _params) do
    body = conn.body_params

    with {:ok, contract_name} <- require_param(body, "contract"),
         {:ok, topic} <- require_param(body, "topic"),
         {:ok, contract_spec} <- AgentOS.Contracts.Loader.load(contract_name) do
      env = body["env"] || %{}
      opts = %{env: env}
      input = %{topic: topic}
      pipeline_id = "pipeline_#{:erlang.unique_integer([:positive])}"

      # Track job for status queries
      try do
        AgentOS.JobTracker.track(pipeline_id, :running)
      catch
        _, _ -> :ok
      end

      case AgentOS.Pipeline.run(contract_spec, input, opts) do
        {:ok, artifacts} ->
          stages =
            contract_spec.stages
            |> Enum.map(fn stage -> %{name: stage.name, instructions: stage.instructions} end)

          json_resp(conn, 200, %{artifacts: artifacts, stages: stages})

        {:error, reason} ->
          json_resp(conn, 500, %{error: "pipeline_failed", detail: inspect(reason)})
      end
    else
      {:error, msg} ->
        json_resp(conn, 400, %{error: inspect(msg)})
    end
  end

  # ── GET /api/v1/contracts ────────────────────────────────────────

  @doc """
  Lists all available contract names.
  """
  @spec list_contracts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list_contracts(conn, _params) do
    contracts =
      AgentOS.Contracts.Loader.list()
      |> Enum.map(fn name ->
        case AgentOS.Contracts.Loader.load(name) do
          {:ok, spec} ->
            %{
              name: spec.name,
              description: spec.description,
              stages:
                Enum.map(spec.stages, fn s ->
                  %{name: s.name, instructions: s.instructions}
                end),
              required_artifacts: spec.required_artifacts,
              model: spec.model,
              provider: spec.provider,
              max_retries: spec.max_retries,
              credentials: spec.credentials
            }

          _ ->
            %{name: name}
        end
      end)

    json_resp(conn, 200, %{contracts: contracts})
  end

  # ── Private ──────────────────────────────────────────────────────

  defp parse_type(nil), do: {:error, "missing required field: type"}
  defp parse_type(type_str) when is_binary(type_str) do
    type_atom = String.to_atom(type_str)
    case AgentScheduler.Agents.Registry.lookup(type_atom) do
      {:ok, _module} -> {:ok, type_atom}
      {:error, :not_found} ->
        {:error, "unknown agent type: #{type_str}"}
    end
  end

  defp require_param(body, key) do
    case body[key] do
      nil -> {:error, "missing required field: #{key}"}
      val -> {:ok, val}
    end
  end

  defp resolve_contract(_), do: AgentOS.Contracts.ResearchContract

  defp maybe_set_model(spec, nil), do: spec

  defp maybe_set_model(spec, model) do
    llm = Map.put(spec.llm_config, :model, model)
    %{spec | llm_config: llm}
  end

  defp maybe_set_provider(spec, nil), do: spec

  defp maybe_set_provider(spec, provider) do
    case parse_provider(provider) do
      {:ok, provider_atom} ->
        llm = Map.put(spec.llm_config, :provider, provider_atom)
        %{spec | llm_config: llm, provider: provider_atom}

      :error ->
        spec
    end
  end

  defp parse_provider("openai"), do: {:ok, :openai}
  defp parse_provider("anthropic"), do: {:ok, :anthropic}
  defp parse_provider("ollama"), do: {:ok, :ollama}
  defp parse_provider(_), do: :error

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
