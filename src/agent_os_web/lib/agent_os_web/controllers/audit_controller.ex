defmodule AgentOS.Web.Controllers.AuditController do
  @moduledoc """
  REST endpoints for querying the pipeline audit trail.

  - `GET /api/v1/audit/:pipeline_id` — full audit trail for a run
  - `GET /api/v1/audit/:pipeline_id/:stage/proof` — proof record for a stage

  Uses direct calls to `AgentOS.Audit` since `:agent_os_web` depends on
  `:agent_os` at compile time.
  """

  import Plug.Conn

  @doc "Returns the full audit trail for `pipeline_id`."
  @spec trail(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def trail(conn, pipeline_id) do
    case AgentOS.Audit.get_audit_trail(pipeline_id) do
      {:ok, entries} ->
        json_resp(conn, 200, %{pipeline_id: pipeline_id, entries: entries})

      {:error, reason} ->
        json_resp(conn, 404, %{error: inspect(reason)})
    end
  end

  @doc "Returns the proof record for a specific stage."
  @spec proof(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def proof(conn, pipeline_id, stage) do
    case AgentOS.Audit.get_stage_proof(pipeline_id, stage) do
      {:ok, proof_entry} ->
        json_resp(conn, 200, proof_entry)

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "not_found"})
    end
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
