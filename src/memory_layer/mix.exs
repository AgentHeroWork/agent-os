defmodule MemoryLayer.MixProject do
  use Mix.Project

  def project do
    [
      app: :memory_layer,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "MemoryLayer",
      description: "Typed filesystem for persistent agent cognition — Part III of the AI OS",
      source_url: "https://github.com/AgentHeroWork/agent-os",
      docs: [
        main: "MemoryLayer",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia, :crypto],
      mod: {MemoryLayer, []}
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
