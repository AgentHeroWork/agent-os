defmodule AgentScheduler.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_scheduler,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "AgentScheduler",
      description: "AI Agent Scheduler — OTP-based process management for AI agent orchestration",
      source_url: "https://github.com/AgentHeroWork/agent-os",
      docs: [main: "AgentScheduler", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {AgentScheduler, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
