defmodule MemoryLayer.StorageTest do
  use ExUnit.Case, async: false

  alias MemoryLayer.Storage

  setup do
    # Initialize ETS tables (Mnesia may already be running)
    try do
      :ets.new(:memory_working, [:named_table, :set, :public, read_concurrency: true])
    rescue
      ArgumentError -> :ets.delete_all_objects(:memory_working)
    end

    try do
      :ets.new(:memory_lru, [:named_table, :ordered_set, :public])
    rescue
      ArgumentError -> :ets.delete_all_objects(:memory_lru)
    end

    # Initialize Mnesia
    :mnesia.create_schema([node()])
    :mnesia.start()

    :mnesia.create_table(:memories, [
      {:attributes, [:id, :data]},
      {:type, :set}
    ])

    :mnesia.wait_for_tables([:memories], 5_000)
    :mnesia.clear_table(:memories)

    # Storage may already be running from the application startup
    case start_supervised(Storage) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "save and recall" do
    test "saves to ETS and recalls" do
      memory = %{id: "mem_1", type: :fact, data: %{assertion: "CERN exists"}}
      assert :ok = Storage.save(memory)

      assert {:ok, ^memory} = Storage.recall("mem_1")
    end

    test "recall returns not_found for missing ID" do
      assert {:error, :not_found} = Storage.recall("nonexistent")
    end

    test "saves to Mnesia and recalls after ETS eviction" do
      memory = %{id: "mem_2", type: :fact, data: %{assertion: "test"}}
      Storage.save(memory)

      # Delete from ETS to force Mnesia fallback
      :ets.delete(:memory_working, "mem_2")

      assert {:ok, ^memory} = Storage.recall("mem_2")
    end
  end

  describe "search" do
    test "searches by text match" do
      Storage.save(%{id: "m1", type: :fact, data: %{assertion: "particle physics"}})
      Storage.save(%{id: "m2", type: :fact, data: %{assertion: "cooking recipes"}})

      {:ok, results} = Storage.search("particle")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == "m1"))
    end

    test "search with empty query returns all" do
      Storage.save(%{id: "m1", type: :fact, data: %{text: "a"}})
      Storage.save(%{id: "m2", type: :fact, data: %{text: "b"}})

      {:ok, results} = Storage.search("")
      assert length(results) >= 2
    end
  end

  describe "delete" do
    test "soft-deletes a memory" do
      memory = %{id: "del_1", type: :fact, data: %{text: "to delete"}}
      Storage.save(memory)

      assert :ok = Storage.delete("del_1")

      {:ok, deleted} = Storage.recall("del_1")
      assert deleted.deleted_at != nil
    end
  end

  describe "update" do
    test "updates a memory" do
      Storage.save(%{id: "upd_1", type: :fact, data: %{text: "original"}})
      Storage.update(%{id: "upd_1", type: :fact, data: %{text: "updated"}})

      {:ok, memory} = Storage.recall("upd_1")
      assert memory.data.text == "updated"
    end
  end
end
