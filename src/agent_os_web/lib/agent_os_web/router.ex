defmodule AgentOS.Web.Router do
  @moduledoc """
  HTTP router for the Agent OS REST API.

  All routes are namespaced under `/api/v1` and return JSON responses.
  Bearer token authentication is enforced via `AgentOS.Web.Plugs.Auth`.
  """

  use Plug.Router

  alias AgentOS.Web.Controllers.{
    HealthController,
    AgentController,
    JobController,
    ToolController,
    MemoryController,
    VMController
  }

  plug Plug.Logger
  plug AgentOS.Web.Plugs.Auth

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # ── Health ──────────────────────────────────────────────────────────

  get "/api/v1/health" do
    HealthController.call(conn)
  end

  # ── Agents ──────────────────────────────────────────────────────────

  post "/api/v1/agents" do
    AgentController.create(conn)
  end

  get "/api/v1/agents" do
    AgentController.index(conn)
  end

  get "/api/v1/agents/:id" do
    AgentController.show(conn, id)
  end

  post "/api/v1/agents/:id/start" do
    AgentController.start(conn, id)
  end

  post "/api/v1/agents/:id/stop" do
    AgentController.stop(conn, id)
  end

  get "/api/v1/agents/:id/logs" do
    AgentController.logs(conn, id)
  end

  # ── Jobs ────────────────────────────────────────────────────────────

  post "/api/v1/jobs" do
    JobController.create(conn)
  end

  get "/api/v1/jobs/:id" do
    JobController.show(conn, id)
  end

  # ── Tools ───────────────────────────────────────────────────────────

  get "/api/v1/tools" do
    ToolController.index(conn)
  end

  # ── Memory ──────────────────────────────────────────────────────────

  post "/api/v1/memory" do
    MemoryController.create(conn)
  end

  get "/api/v1/memory/search" do
    MemoryController.search(conn)
  end

  get "/api/v1/memory/:id" do
    MemoryController.show(conn, id)
  end

  # ── VM Proxy (called by agents inside microVMs) ────────────────

  post "/api/v1/vm/llm/chat" do
    VMController.llm_chat(conn)
  end

  # ── Catch-all ───────────────────────────────────────────────────────

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end
end
