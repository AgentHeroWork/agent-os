defmodule AgentOS.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_os_web,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "AgentOS.Web",
      description: "REST API layer for the AI Operating System — Plug/Cowboy HTTP interface",
      source_url: "https://github.com/AgentHeroWork/agent-os",
      docs: [main: "AgentOS.Web", extras: []]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AgentOS.Web, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:agent_os, path: "../agent_os"},
      {:agent_scheduler, path: "../agent_scheduler"},
      {:tool_interface, path: "../tool_interface"},
      {:memory_layer, path: "../memory_layer"},
      {:planner_engine, path: "../planner_engine"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
