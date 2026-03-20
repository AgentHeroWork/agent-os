defmodule AgentOS.Web.Controllers.RunController do
  @moduledoc """
  REST controller for agent execution and pipeline runs.

  Provides endpoints to run a single agent, execute a multi-stage pipeline,
  and list available contracts. All calls to AgentOS core modules (AgentSpec,
  AgentRunner, Pipeline, Contracts.Loader) use runtime dispatch via apply/3
  since the :agent_os app is not a compile-time dependency of :agent_os_web.
  """

  import Plug.Conn

  # Runtime module references — these live in :agent_os, which depends on
  # :agent_os_web (not the reverse), so we cannot reference them at compile time.
  @agent_runner AgentOS.AgentRunner
  @pipeline AgentOS.Pipeline
  @loader AgentOS.Contracts.Loader
  @agent_spec AgentOS.AgentSpec
  @research_contract AgentOS.Contracts.ResearchContract

  # ── POST /api/v1/run ─────────────────────────────────────────────

  @doc """
  Runs a single agent with a resolved contract.

  Expects JSON body with `type`, `topic`, and optional `model`, `provider`.
  Builds an AgentSpec, resolves the contract, and delegates to AgentRunner.
  """
  @spec run_single(Plug.Conn.t()) :: Plug.Conn.t()
  def run_single(conn) do
    body = conn.body_params

    with {:ok, type} <- parse_type(body["type"]),
         {:ok, topic} <- require_param(body, "topic") do
      agent_id = "api_#{:erlang.unique_integer([:positive])}"

      spec = struct!(@agent_spec, %{
        type: type,
        name: "api_#{:erlang.unique_integer([:positive])}",
        oversight: :autonomous_escalation,
        metadata: %{agent_id: agent_id, output_dir: "/tmp/agent-os/artifacts"}
      })

      spec =
        spec
        |> maybe_set_model(body["model"])
        |> maybe_set_provider(body["provider"])

      contract = resolve_contract(type)
      input = %{input: %{topic: topic}}

      case apply(@agent_runner, :run, [spec, contract, input]) do
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
  @spec run_pipeline(Plug.Conn.t()) :: Plug.Conn.t()
  def run_pipeline(conn) do
    body = conn.body_params

    with {:ok, contract_name} <- require_param(body, "contract"),
         {:ok, topic} <- require_param(body, "topic"),
         {:ok, contract_spec} <- apply(@loader, :load, [contract_name]) do
      env = body["env"] || %{}
      opts = %{env: env}
      input = %{topic: topic}

      case apply(@pipeline, :run, [contract_spec, input, opts]) do
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
  @spec list_contracts(Plug.Conn.t()) :: Plug.Conn.t()
  def list_contracts(conn) do
    contracts = apply(@loader, :list, [])
    json_resp(conn, 200, %{contracts: contracts})
  end

  # ── Private ──────────────────────────────────────────────────────

  defp parse_type("openclaw"), do: {:ok, :open_claw}
  defp parse_type("nemoclaw"), do: {:ok, :nemo_claw}
  defp parse_type("open_claw"), do: {:ok, :open_claw}
  defp parse_type("nemo_claw"), do: {:ok, :nemo_claw}
  defp parse_type(nil), do: {:error, "missing required field: type"}
  defp parse_type(other), do: {:error, "unknown agent type: #{other}"}

  defp require_param(body, key) do
    case body[key] do
      nil -> {:error, "missing required field: #{key}"}
      val -> {:ok, val}
    end
  end

  defp resolve_contract(:open_claw), do: @research_contract
  defp resolve_contract(:nemo_claw), do: @research_contract
  defp resolve_contract(_), do: @research_contract

  defp maybe_set_model(spec, nil), do: spec

  defp maybe_set_model(spec, model) do
    llm = Map.put(spec.llm_config, :model, model)
    %{spec | llm_config: llm}
  end

  defp maybe_set_provider(spec, nil), do: spec

  defp maybe_set_provider(spec, provider) do
    provider_atom = String.to_existing_atom(provider)
    llm = Map.put(spec.llm_config, :provider, provider_atom)
    %{spec | llm_config: llm, provider: provider_atom}
  rescue
    ArgumentError -> spec
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
