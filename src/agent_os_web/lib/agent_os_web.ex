defmodule AgentOS.Web do
  @moduledoc """
  REST API application for the AI Operating System.

  Starts a Phoenix endpoint exposing the Agent OS capabilities
  over a JSON REST API. The port defaults to 4000 and can be overridden
  via the `AGENT_OS_PORT` environment variable.

  ## Supervision Tree

      AgentOS.Web (Application)
      ├── Phoenix.PubSub (AgentOS.Web.PubSub)
      └── AgentOS.Web.Endpoint (Phoenix on :http)

  All routes are defined in `AgentOS.Web.Router`.
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    port = port()

    # Configure the endpoint at runtime before starting the supervision tree
    Application.put_env(:agent_os_web, AgentOS.Web.Endpoint,
      http: [port: port],
      server: true,
      pubsub_server: AgentOS.Web.PubSub,
      secret_key_base: secret_key_base(),
      render_errors: [
        formats: [json: AgentOS.Web.ErrorJSON],
        layout: false
      ]
    )

    children = [
      {Phoenix.PubSub, name: AgentOS.Web.PubSub},
      AgentOS.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: AgentOS.Web.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        require Logger
        Logger.info("AgentOS.Web started on port #{port} (Phoenix)")
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

  defp secret_key_base do
    case System.get_env("SECRET_KEY_BASE") do
      nil ->
        # Generate a deterministic key for dev/test; production should set SECRET_KEY_BASE
        :crypto.hash(:sha512, "agent-os-dev-secret-key-base-#{node()}")
        |> Base.encode64(padding: false)

      key ->
        key
    end
  end
end
