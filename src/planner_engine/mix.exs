defmodule PlannerEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :planner_engine,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "PlannerEngine",
      description: "Order book dynamics and natural transformation planner for AI OS",
      source_url: "https://github.com/AgentHeroWork/agent-os",
      docs: [main: "PlannerEngine", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia],
      mod: {PlannerEngine.Application, []}
    ]
  end

  defp deps do
    [
      {:uuid, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
