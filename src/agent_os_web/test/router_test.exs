defmodule AgentOS.Web.RouterTest do
  use ExUnit.Case, async: false

  alias AgentOS.Web.Endpoint

  @opts Endpoint.init([])

  setup_all do
    # Ensure dependent applications are started for integration testing.
    # If they are already running (e.g. from umbrella boot), these are no-ops.
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:agent_scheduler)
    Application.ensure_all_started(:tool_interface)
    Application.ensure_all_started(:memory_layer)
    Application.ensure_all_started(:planner_engine)

    # Ensure Mnesia tables exist for memory tests
    ensure_mnesia_tables()

    # Make sure no API key is required during tests (dev mode).
    System.delete_env("AGENT_OS_API_KEY")

    :ok
  end

  # ── Health ──────────────────────────────────────────────────────────

  test "GET /api/v1/health returns 200 with status ok" do
    conn = call(:get, "/api/v1/health")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["version"] == "0.1.0"
    assert is_integer(body["uptime_ms"])
  end

  # ── Agents ──────────────────────────────────────────────────────────

  test "POST /api/v1/agents with valid body returns 201" do
    conn =
      call(:post, "/api/v1/agents", %{
        "type" => "openclaw",
        "name" => "test_agent",
        "oversight" => "autonomous_escalation"
      })

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["type"] == "openclaw"
    assert body["name"] == "test_agent"
    assert is_binary(body["agent_id"])
  end

  test "POST /api/v1/agents with missing type returns 400" do
    conn = call(:post, "/api/v1/agents", %{"name" => "bad"})

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "type"
  end

  test "GET /api/v1/agents returns 200 with agents" do
    # Ensure at least one agent exists
    call(:post, "/api/v1/agents", %{
      "type" => "nemoclaw",
      "name" => "list_test"
    })

    conn = call(:get, "/api/v1/agents")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
    assert is_list(body["agents"])
  end

  # ── Tools ───────────────────────────────────────────────────────────

  test "GET /api/v1/tools returns 200 with tools" do
    conn = call(:get, "/api/v1/tools")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
  end

  defp ensure_mnesia_tables do
    :mnesia.create_schema([node()])
    :mnesia.start()

    for table <- [:memories, :versions, :edges] do
      :mnesia.create_table(table, [
        {:attributes, [:id, :data]},
        {:type, :set}
      ])
    end

    :mnesia.wait_for_tables([:memories, :versions, :edges], 5_000)
  end

  # ── Memory ──────────────────────────────────────────────────────────

  test "POST /api/v1/memory returns 201" do
    conn =
      call(:post, "/api/v1/memory", %{
        "schema_type" => "episodic",
        "data" => %{"event" => "test_memory", "content" => "hello"}
      })

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "saved"
  end

  test "GET /api/v1/memory/search?q=test returns 200" do
    conn = call(:get, "/api/v1/memory/search?q=test")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
  end

  # ── 404 ─────────────────────────────────────────────────────────────

  test "unknown route returns 404" do
    conn = call(:get, "/api/v1/nonexistent")

    assert conn.status == 404
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp call(method, path, body \\ nil) do
    conn =
      if body do
        Plug.Test.conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        Plug.Test.conn(method, path)
      end

    Endpoint.call(conn, @opts)
  end
end
