defmodule AgentOS.Web.Endpoint do
  @moduledoc """
  Phoenix endpoint for the Agent OS REST API.

  Handles HTTP request processing, JSON parsing, CORS, and routing.
  Replaces the previous direct Plug.Cowboy setup with Phoenix's
  endpoint supervision and configuration.
  """

  use Phoenix.Endpoint, otp_app: :agent_os_web

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug CORSPlug, origin: ["http://localhost:3000", "http://localhost:3001"]

  plug AgentOS.Web.Router
end
