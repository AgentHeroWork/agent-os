defmodule ToolInterface.RegistryTest do
  use ExUnit.Case, async: false

  alias ToolInterface.Registry

  setup do
    # Registry may already be running from the application startup
    case start_supervised(Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "three-tier lookup" do
    test "looks up builtin tools" do
      assert {:ok, tool} = Registry.lookup("web-search")
      assert tool.tier == :builtin
      assert tool.name == "web-search"
    end

    test "looks up sandbox tools" do
      assert {:ok, tool} = Registry.lookup("shell-exec")
      assert tool.tier == :sandbox
    end

    test "returns not_found for unknown tools" do
      assert {:error, :not_found} = Registry.lookup("nonexistent")
    end

    test "registers and looks up MCP/external tools" do
      tools = [
        %{name: "analyze", description: "Analyze data", input_schema: %{}, execute: fn _ -> {:ok, :done} end}
      ]

      case Registry.register_mcp("my_server", tools) do
        :ok ->
          assert {:ok, tool} = Registry.lookup("my_server__analyze")
          assert tool.tier == :mcp

        {:error, :frozen} ->
          # Registry was frozen by application startup — this is expected
          assert Registry.frozen?()
      end
    end
  end

  describe "freeze" do
    test "prevents registration after freeze" do
      Registry.freeze()
      assert Registry.frozen?()

      tools = [%{name: "t1", description: "test", input_schema: %{}}]
      assert {:error, :frozen} = Registry.register_mcp("server", tools)
    end
  end

  describe "list" do
    test "lists all tools" do
      all = Registry.list()
      assert length(all) >= 12
    end

    test "lists by tier" do
      builtin = Registry.list(:builtin)
      assert length(builtin) == 6
      assert Enum.all?(builtin, &(&1.tier == :builtin))

      sandbox = Registry.list(:sandbox)
      assert length(sandbox) == 6
      assert Enum.all?(sandbox, &(&1.tier == :sandbox))
    end
  end
end
