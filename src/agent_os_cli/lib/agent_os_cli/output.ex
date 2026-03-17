defmodule AgentOS.CLI.Output do
  @moduledoc "Output formatting for CLI: tables, JSON, info/error messages."

  @doc """
  Prints an ASCII table with the given headers and rows.

  Column widths are calculated automatically based on the widest value
  in each column (including the header).

  ## Example

      table(["ID", "Name"], [["abc", "Alice"], ["def", "Bob"]])
  """
  def table(headers, rows) do
    all_rows = [headers | rows]

    widths =
      all_rows
      |> Enum.reduce(List.duplicate(0, length(headers)), fn row, acc ->
        row
        |> Enum.zip(acc)
        |> Enum.map(fn {cell, max_w} -> max(String.length(to_string(cell)), max_w) end)
      end)

    separator = "+-" <> Enum.map_join(widths, "-+-", &String.duplicate("-", &1)) <> "-+"

    format_row = fn row ->
      cells =
        row
        |> Enum.zip(widths)
        |> Enum.map_join(" | ", fn {cell, w} ->
          String.pad_trailing(to_string(cell), w)
        end)

      "| #{cells} |"
    end

    IO.puts(separator)
    IO.puts(format_row.(headers))
    IO.puts(separator)
    Enum.each(rows, fn row -> IO.puts(format_row.(row)) end)
    IO.puts(separator)
  end

  @doc "Prints data as formatted JSON to stdout."
  def json(data) do
    data
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  @doc "Prints an informational message to stdout."
  def info(message) do
    IO.puts(message)
  end

  @doc "Prints an error message to stderr."
  def error(message) do
    IO.puts(:stderr, "Error: #{message}")
  end

  @doc "Prints a success message to stdout."
  def success(message) do
    IO.puts("OK: #{message}")
  end
end
