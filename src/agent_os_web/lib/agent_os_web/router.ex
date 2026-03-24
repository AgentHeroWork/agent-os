defmodule AgentOS.Web.Router do
  @moduledoc """
  Phoenix router for the Agent OS REST API.

  All routes are namespaced under `/api/v1` and return JSON responses.
  Bearer token authentication is enforced via `AgentOS.Web.Plugs.Auth`
  on all routes except the VM proxy scope.
  """

  use Phoenix.Router

  import Plug.Conn

  pipeline :api do
    plug :accepts, ["json"]
    plug AgentOS.Web.Plugs.Auth
  end

  pipeline :vm do
    plug :accepts, ["json"]
    # No auth — VM routes are exempt (microVM agents use JOB_TOKEN)
  end

  scope "/api/v1", AgentOS.Web.Controllers do
    pipe_through :api

    # Health
    get "/health", HealthController, :check

    # Agents
    post "/agents", AgentController, :create
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show
    post "/agents/:id/start", AgentController, :start
    post "/agents/:id/stop", AgentController, :stop
    get "/agents/:id/logs", AgentController, :logs

    # Jobs
    post "/jobs", JobController, :create
    get "/jobs/:id", JobController, :show

    # Tools
    get "/tools", ToolController, :index

    # Memory
    post "/memory", MemoryController, :create
    get "/memory/search", MemoryController, :search
    get "/memory/:id", MemoryController, :show

    # Run / Pipeline
    post "/run", RunController, :run_single
    post "/pipeline/run", RunController, :run_pipeline
    get "/contracts", RunController, :list_contracts

    # Audit
    get "/audit/:pipeline_id", AuditController, :trail
    get "/audit/:pipeline_id/:stage/proof", AuditController, :proof

    # SSE Events
    get "/events/:run_id", EventsController, :stream
  end

  scope "/api/v1/vm", AgentOS.Web.Controllers do
    pipe_through :vm

    post "/llm/chat", VMController, :llm_chat
  end
end
