defmodule AgentOS.Web.Controllers.EscrowController do
  @moduledoc """
  REST controller for escrow balance queries and management.

  Provides endpoints for querying participant balances and setting initial balances.
  Delegates to `PlannerEngine.Escrow` for all financial operations.
  """

  import Plug.Conn

  @doc """
  Returns the escrow balance for a given participant ID.
  """
  @spec balance(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def balance(conn, id) do
    case PlannerEngine.Escrow.balance(id) do
      {:ok, balance} -> json_resp(conn, 200, balance)
      {:error, reason} -> json_resp(conn, 404, %{error: inspect(reason)})
    end
  end

  @doc """
  Sets the balance for a participant.

  Expects JSON body with `participant_id` (string) and `amount` (integer).
  """
  @spec set_balance(Plug.Conn.t()) :: Plug.Conn.t()
  def set_balance(conn) do
    body = conn.body_params

    case PlannerEngine.Escrow.set_balance(body["participant_id"], body["amount"]) do
      :ok -> json_resp(conn, 200, %{status: "ok"})
      {:error, reason} -> json_resp(conn, 400, %{error: inspect(reason)})
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
