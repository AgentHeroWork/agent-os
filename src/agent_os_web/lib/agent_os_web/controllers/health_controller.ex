defmodule AgentOS.Web.Controllers.HealthController do
  @moduledoc """
  Health-check endpoint for the Agent OS API.

  Returns server status, version, and uptime in milliseconds.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  @version "0.1.0"

  @doc """
  Returns a 200 JSON response with status, version, and uptime.
  """
  @spec check(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def check(conn, _params) do
    uptime_ms = System.monotonic_time(:millisecond) - start_time()

    body =
      Jason.encode!(%{
        status: "ok",
        version: @version,
        uptime_ms: uptime_ms
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Capture the monotonic start time once at compile time.
  @start_time System.monotonic_time(:millisecond)
  defp start_time, do: @start_time
end
