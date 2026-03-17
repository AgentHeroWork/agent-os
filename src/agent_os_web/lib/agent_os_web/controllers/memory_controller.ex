defmodule AgentOS.Web.Controllers.MemoryController do
  @moduledoc """
  REST controller for the memory layer.

  Provides endpoints to save, recall, and search agent memories
  through the `MemoryLayer.Storage` interface.
  """

  import Plug.Conn

  @doc """
  Saves a new memory entry.

  Expects JSON body with `schema_type` and `data`.
  Returns 201 with the saved memory metadata on success.
  """
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    body = conn.body_params

    with {:ok, schema_type} <- require_param(body, "schema_type"),
         {:ok, data} <- require_param(body, "data") do
      id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      memory = %{
        id: id,
        schema_type: String.to_atom(schema_type),
        data: data,
        timestamp: DateTime.utc_now()
      }

      case MemoryLayer.Storage.save(memory) do
        :ok ->
          json_resp(conn, 201, %{
            schema_type: schema_type,
            status: "saved"
          })

        {:error, reason} ->
          json_resp(conn, 500, %{error: "save_failed", detail: inspect(reason)})
      end
    else
      {:error, msg} ->
        json_resp(conn, 400, %{error: msg})
    end
  end

  @doc """
  Searches memories by query string.

  Uses the `q` query parameter for the search term. Supports optional
  `limit` and `offset` query parameters.
  """
  @spec search(Plug.Conn.t()) :: Plug.Conn.t()
  def search(conn) do
    params = Plug.Conn.fetch_query_params(conn).query_params
    query = params["q"] || ""

    opts =
      []
      |> maybe_add_int(:limit, params["limit"])
      |> maybe_add_int(:offset, params["offset"])

    try do
      {:ok, results} = MemoryLayer.Storage.search(query, opts)
      json_resp(conn, 200, results)
    rescue
      e ->
        json_resp(conn, 500, %{error: "search_failed", detail: Exception.message(e)})
    end
  end

  @doc """
  Recalls a single memory by ID.
  """
  @spec show(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def show(conn, id) do
    case MemoryLayer.Storage.recall(id) do
      {:ok, memory} ->
        json_resp(conn, 200, memory)

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "memory_not_found", id: id})

      {:error, reason} ->
        json_resp(conn, 500, %{error: inspect(reason)})
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp require_param(body, key) do
    case body[key] do
      nil -> {:error, "missing required field: #{key}"}
      val -> {:ok, val}
    end
  end

  defp maybe_add_int(opts, _key, nil), do: opts

  defp maybe_add_int(opts, key, val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> [{key, n} | opts]
      _ -> opts
    end
  end

  defp maybe_add_int(opts, _key, _val), do: opts

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
