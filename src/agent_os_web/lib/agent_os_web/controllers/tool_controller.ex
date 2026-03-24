defmodule AgentOS.Web.Controllers.ToolController do
  @moduledoc """
  REST controller for tool registry queries.

  Exposes the `ToolInterface` registry, returning tool metadata
  (name, tier, description, input schema) without leaking execute/validate functions.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  @doc """
  Lists all registered tools, optionally filtered by the `tier` query parameter.

  Supported tiers: `builtin`, `sandbox`, `external`.
  Returns a JSON array of tool specification maps.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    tier = parse_tier(params["tier"])

    tools =
      ToolInterface.list_tools(tier)
      |> Enum.map(&sanitize_tool/1)

    json_resp(conn, 200, tools)
  end

  # ── Private ───────────────────────────────────────────────────────

  defp parse_tier(nil), do: nil
  defp parse_tier("builtin"), do: :builtin
  defp parse_tier("sandbox"), do: :sandbox
  defp parse_tier("external"), do: :external
  defp parse_tier(_), do: nil

  defp sanitize_tool(tool) when is_map(tool) do
    tool
    |> Map.take([:name, :tier, :description, :input_schema, :id])
    |> Map.new(fn
      {:tier, v} when is_atom(v) -> {:tier, to_string(v)}
      pair -> pair
    end)
  end

  defp sanitize_tool(_), do: %{}

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
