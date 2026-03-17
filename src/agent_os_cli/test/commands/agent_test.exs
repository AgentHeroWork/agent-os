defmodule AgentOS.CLI.Test do
  use ExUnit.Case, async: true

  describe "parse_global_opts/1" do
    test "extracts --target flag" do
      {opts, rest} = AgentOS.CLI.parse_global_opts(["--target", "fly", "agent", "list"])
      assert opts.target == "fly"
      assert rest == ["agent", "list"]
    end

    test "extracts --host flag" do
      {opts, rest} = AgentOS.CLI.parse_global_opts(["--host", "https://my.api", "health"])
      assert opts.host == "https://my.api"
      assert rest == ["health"]
    end

    test "extracts --json flag" do
      {opts, rest} = AgentOS.CLI.parse_global_opts(["--json", "agent", "list"])
      assert opts.json == true
      assert rest == ["agent", "list"]
    end

    test "extracts --api-key flag" do
      {opts, _rest} = AgentOS.CLI.parse_global_opts(["--api-key", "secret123", "health"])
      assert opts.api_key == "secret123"
    end

    test "defaults target to local when no flag or env" do
      System.delete_env("AGENT_OS_TARGET")
      {opts, _rest} = AgentOS.CLI.parse_global_opts(["health"])
      assert opts.target == "local"
    end

    test "defaults json to false" do
      {opts, _rest} = AgentOS.CLI.parse_global_opts(["health"])
      assert opts.json == false
    end

    test "handles multiple global flags together" do
      argv = ["--target", "fly", "--json", "--host", "https://x.com", "agent", "create"]
      {opts, rest} = AgentOS.CLI.parse_global_opts(argv)
      assert opts.target == "fly"
      assert opts.host == "https://x.com"
      assert opts.json == true
      assert rest == ["agent", "create"]
    end

    test "returns all args when no global flags" do
      {_opts, rest} = AgentOS.CLI.parse_global_opts(["agent", "list"])
      assert rest == ["agent", "list"]
    end
  end

  describe "Agent.parse_create_opts/1" do
    test "parses --type and --name" do
      opts = AgentOS.CLI.Commands.Agent.parse_create_opts(["--type", "openclaw", "--name", "r1"])
      assert opts[:type] == "openclaw"
      assert opts[:name] == "r1"
    end

    test "parses --oversight" do
      opts =
        AgentOS.CLI.Commands.Agent.parse_create_opts([
          "--type",
          "openclaw",
          "--name",
          "r1",
          "--oversight",
          "strict"
        ])

      assert opts[:oversight] == "strict"
    end

    test "returns empty map for no args" do
      opts = AgentOS.CLI.Commands.Agent.parse_create_opts([])
      assert opts == %{}
    end
  end
end

defmodule AgentOS.CLI.OutputTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "table/2" do
    test "prints a formatted table" do
      output =
        capture_io(fn ->
          AgentOS.CLI.Output.table(
            ["ID", "Name"],
            [["abc", "Alice"], ["defgh", "Bob"]]
          )
        end)

      assert output =~ "| ID"
      assert output =~ "| Name"
      assert output =~ "| abc"
      assert output =~ "| Alice"
      assert output =~ "| defgh"
      assert output =~ "+-"
    end
  end

  describe "json/1" do
    test "prints formatted JSON" do
      output = capture_io(fn -> AgentOS.CLI.Output.json(%{id: "abc", name: "test"}) end)
      decoded = Jason.decode!(output)
      assert decoded["id"] == "abc"
      assert decoded["name"] == "test"
    end
  end

  describe "info/1" do
    test "prints to stdout" do
      output = capture_io(fn -> AgentOS.CLI.Output.info("hello") end)
      assert output =~ "hello"
    end
  end

  describe "error/1" do
    test "prints to stderr" do
      output = capture_io(:stderr, fn -> AgentOS.CLI.Output.error("oops") end)
      assert output =~ "Error: oops"
    end
  end

  describe "success/1" do
    test "prints OK prefix" do
      output = capture_io(fn -> AgentOS.CLI.Output.success("done") end)
      assert output =~ "OK: done"
    end
  end
end
