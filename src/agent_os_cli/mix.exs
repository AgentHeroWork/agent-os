defmodule AgentOS.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_os_cli,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl]]
  end

  defp escript do
    [main_module: AgentOS.CLI, name: "agent-os"]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:agent_os, path: "../agent_os"},
      {:agent_scheduler, path: "../agent_scheduler"}
    ]
  end
end
