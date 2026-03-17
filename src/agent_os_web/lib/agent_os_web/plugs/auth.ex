defmodule AgentOS.Web.Plugs.Auth do
  @moduledoc """
  Bearer token authentication plug.

  Validates the `Authorization: Bearer <token>` header against the
  `AGENT_OS_API_KEY` environment variable.

  When `AGENT_OS_API_KEY` is not set, all requests are allowed through
  (dev mode). When set, requests without a valid bearer token receive
  a 401 Unauthorized response.
  """

  import Plug.Conn
  @behaviour Plug

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case System.get_env("AGENT_OS_API_KEY") do
      nil ->
        # Dev mode — no auth required
        conn

      expected_key ->
        case get_bearer_token(conn) do
          {:ok, ^expected_key} ->
            conn

          {:ok, _wrong_token} ->
            unauthorized(conn)

          :error ->
            unauthorized(conn)
        end
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    body = Jason.encode!(%{error: "unauthorized", message: "Invalid or missing bearer token"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
