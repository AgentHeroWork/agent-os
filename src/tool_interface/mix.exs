defmodule ToolInterface.MixProject do
  use Mix.Project

  def project do
    [
      app: :tool_interface,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ToolInterface",
      description: "AI OS Tool Interface Layer — capability-based tool registry with sandboxed execution",
      source_url: "https://github.com/AgentHeroWork/agent-os",
      docs: [main: "ToolInterface", extras: []]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ToolInterface.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:finch, "~> 0.18"},
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
