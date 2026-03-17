defmodule AgentOSTest do
  use ExUnit.Case, async: false

  describe "status/0" do
    test "returns status map with all subsystems" do
      status = AgentOS.status()
      assert is_map(status)
      assert status.scheduler.running == true
      assert is_list(status.tools)
      assert status.memory.running == true
      assert status.planner.running == true
    end
  end
end
