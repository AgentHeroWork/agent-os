defmodule AgentOS.Web.Controllers.EventsController do
  @moduledoc """
  SSE endpoint that streams pipeline events in real time.

  Subscribes to `Phoenix.PubSub` topic `"pipeline:{run_id}"` and
  forwards `{:stage_complete, stage_name, proof}` messages to the
  client as `text/event-stream` Server-Sent Events.

  ## Usage

      GET /api/v1/events/:run_id
      Accept: text/event-stream

  Events are sent as:

      event: stage_complete
      data: {"stage":"research","proof":{...}}

  The connection is held open until the pipeline finishes (indicated by
  a `{:pipeline_complete, run_id}` message) or the client disconnects.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  require Logger

  @doc """
  Starts an SSE stream for the given `run_id`.

  Subscribes to `"pipeline:{run_id}"` on PubSub and sends events
  as they arrive. Sends a heartbeat comment every 15 seconds to
  keep the connection alive through proxies.
  """
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, %{"run_id" => run_id}) do
    topic = "pipeline:#{run_id}"
    Phoenix.PubSub.subscribe(AgentOS.Web.PubSub, topic)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Send initial connection event
    {:ok, conn} = chunk(conn, encode_sse("connected", %{run_id: run_id}))

    listen_loop(conn, topic)
  end

  # ── Private ───────────────────────────────────────────────────────

  defp listen_loop(conn, topic) do
    receive do
      {:stage_complete, stage_name, proof} ->
        data = %{stage: to_string(stage_name), proof: proof}

        case chunk(conn, encode_sse("stage_complete", data)) do
          {:ok, conn} ->
            listen_loop(conn, topic)

          {:error, _reason} ->
            # Client disconnected
            Phoenix.PubSub.unsubscribe(AgentOS.Web.PubSub, topic)
            conn
        end

      {:pipeline_complete, _run_id} ->
        chunk(conn, encode_sse("pipeline_complete", %{status: "done"}))
        Phoenix.PubSub.unsubscribe(AgentOS.Web.PubSub, topic)
        conn

      {:pipeline_error, _run_id, reason} ->
        chunk(conn, encode_sse("pipeline_error", %{error: inspect(reason)}))
        Phoenix.PubSub.unsubscribe(AgentOS.Web.PubSub, topic)
        conn
    after
      15_000 ->
        # Heartbeat to keep connection alive through proxies
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            listen_loop(conn, topic)

          {:error, _reason} ->
            Phoenix.PubSub.unsubscribe(AgentOS.Web.PubSub, topic)
            conn
        end
    end
  end

  defp encode_sse(event, data) do
    json = Jason.encode!(data)
    "event: #{event}\ndata: #{json}\n\n"
  end
end
