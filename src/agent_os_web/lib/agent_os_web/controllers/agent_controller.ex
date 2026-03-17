defmodule AgentOS.Web.Controllers.AgentController do
  @moduledoc """
  REST controller for agent lifecycle management.

  Provides endpoints to create, list, inspect, start, stop, and
  retrieve logs for AI agents running under the `AgentScheduler` supervision tree.
  """

  import Plug.Conn

  @doc """
  Creates a new agent.

  Expects JSON body with `type` ("openclaw" or "nemoclaw"), `name`, and optional `oversight`.
  Returns 201 with the new agent ID on success.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    body = conn.body_params

    with {:ok, type} <- parse_type(body["type"]),
         {:ok, name} <- require_param(body, "name") do
      profile = agent_profile(type)
      oversight = parse_oversight(body["oversight"])
      agent_id = "#{type}_#{name}_#{:erlang.unique_integer([:positive])}"

      case AgentScheduler.Supervisor.start_agent(
             id: agent_id,
             profile: profile,
             credits: 0,
             oversight: oversight
           ) do
        {:ok, _pid} ->
          json_resp(conn, 201, %{agent_id: agent_id, type: to_string(type), name: name})

        {:error, reason} ->
          json_resp(conn, 500, %{error: "failed_to_start", detail: inspect(reason)})
      end
    else
      {:error, msg} ->
        json_resp(conn, 400, %{error: msg})
    end
  end

  @doc """
  Lists all running agents with their current state.
  """
  @spec index(Plug.Conn.t()) :: Plug.Conn.t()
  def index(conn) do
    agents =
      AgentScheduler.Supervisor.list_agents()
      |> Enum.map(fn {id, _pid} ->
        state =
          case AgentScheduler.Agent.get_state(id) do
            {:ok, s} -> summarize_state(s)
            _ -> %{status: "unknown"}
          end

        Map.put(state, :id, id)
      end)

    json_resp(conn, 200, agents)
  end

  @doc """
  Shows a single agent by ID.
  """
  @spec show(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def show(conn, id) do
    case AgentScheduler.Agent.get_state(id) do
      {:ok, state} ->
        json_resp(conn, 200, Map.put(summarize_state(state), :id, id))

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "agent_not_found", agent_id: id})

      {:error, reason} ->
        json_resp(conn, 500, %{error: inspect(reason)})
    end
  end

  @doc """
  Assigns a job to an agent and starts execution.

  Expects JSON body with `job_spec` map.
  """
  @spec start(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def start(conn, id) do
    job_spec = conn.body_params["job_spec"] || %{}

    case AgentScheduler.Agent.assign_job(id, job_spec) do
      :ok ->
        json_resp(conn, 200, %{agent_id: id, status: "job_assigned"})

      {:ok, _} ->
        json_resp(conn, 200, %{agent_id: id, status: "job_assigned"})

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "agent_not_found", agent_id: id})

      {:error, reason} ->
        json_resp(conn, 500, %{error: inspect(reason)})
    end
  end

  @doc """
  Stops an agent.
  """
  @spec stop(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def stop(conn, id) do
    case AgentScheduler.Supervisor.stop_agent(id) do
      :ok ->
        json_resp(conn, 200, %{agent_id: id, status: "stopped"})

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "agent_not_found", agent_id: id})

      {:error, reason} ->
        json_resp(conn, 500, %{error: inspect(reason)})
    end
  end

  @doc """
  Returns agent metrics and state as logs.
  """
  @spec logs(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def logs(conn, id) do
    case AgentScheduler.Agent.get_state(id) do
      {:ok, state} ->
        json_resp(conn, 200, %{agent_id: id, logs: summarize_state(state)})

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "agent_not_found", agent_id: id})

      {:error, reason} ->
        json_resp(conn, 500, %{error: inspect(reason)})
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp parse_type("openclaw"), do: {:ok, :openclaw}
  defp parse_type("nemoclaw"), do: {:ok, :nemoclaw}
  defp parse_type(nil), do: {:error, "missing required field: type"}
  defp parse_type(other), do: {:error, "unknown agent type: #{other}"}

  defp require_param(body, key) do
    case body[key] do
      nil -> {:error, "missing required field: #{key}"}
      val -> {:ok, val}
    end
  end

  defp agent_profile(:openclaw), do: AgentScheduler.Agents.OpenClaw.profile()
  defp agent_profile(:nemoclaw), do: AgentScheduler.Agents.NemoClaw.profile()

  defp parse_oversight(nil), do: :autonomous_escalation
  defp parse_oversight("autonomous"), do: :autonomous
  defp parse_oversight("autonomous_escalation"), do: :autonomous_escalation
  defp parse_oversight("supervised"), do: :supervised
  defp parse_oversight("human_in_loop"), do: :human_in_loop
  defp parse_oversight(_), do: :autonomous_escalation

  defp summarize_state(state) when is_map(state) do
    state
    |> Map.take([:status, :credits, :oversight, :job, :metrics, :profile])
    |> Map.new(fn {k, v} -> {k, safe_serialize(v)} end)
  end

  defp summarize_state(_), do: %{status: "unknown"}

  defp safe_serialize(%{name: _} = profile) do
    Map.take(profile, [:name, :tier, :default_oversight])
  end

  defp safe_serialize(val) when is_map(val), do: val
  defp safe_serialize(val) when is_atom(val), do: to_string(val)
  defp safe_serialize(val), do: val

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
