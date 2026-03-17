defmodule AgentOS.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_os,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia],
      mod: {AgentOS.Application, []}
    ]
  end

  defp deps do
    [
      {:agent_scheduler, path: "../agent_scheduler"},
      {:tool_interface, path: "../tool_interface"},
      {:memory_layer, path: "../memory_layer"},
      {:planner_engine, path: "../planner_engine"},
      {:agent_os_web, path: "../agent_os_web"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"]
    ]
  end

  defp docs do
    [
      main: "AgentOS",
      extras: ["../../README.md"]
    ]
  end
end
