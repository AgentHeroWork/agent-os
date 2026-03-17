defmodule AgentOS.Web do
  @moduledoc """
  REST API application for the AI Operating System.

  Starts a Plug.Cowboy HTTP server exposing the Agent OS capabilities
  over a JSON REST API. The port defaults to 4000 and can be overridden
  via the `AGENT_OS_PORT` environment variable.

  ## Supervision Tree

      AgentOS.Web (Application)
      └── Plug.Cowboy (AgentOS.Web.Router on :http)

  All routes are defined in `AgentOS.Web.Router`.
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    port = port()

    children = [
      {Plug.Cowboy, scheme: :http, plug: AgentOS.Web.Router, options: [port: port]}
    ]

    opts = [strategy: :one_for_one, name: AgentOS.Web.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        require Logger
        Logger.info("AgentOS.Web started on port #{port}")
        {:ok, pid}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the configured HTTP port.
  """
  @spec port() :: non_neg_integer()
  def port do
    case System.get_env("AGENT_OS_PORT") do
      nil -> 4000
      val -> String.to_integer(val)
    end
  end
end
