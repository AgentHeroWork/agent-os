defmodule AgentOS.Providers.Fly do
  @moduledoc """
  Fly.io provider — runs agents as Fly Machines.

  Uses the Fly Machines API (https://fly.io/docs/machines/api/) to create,
  start, stop, and destroy machines running agent-os containers.

  ## Configuration

  Set the following environment variables:

    * `FLY_API_TOKEN` — Fly.io API token for authentication (required)
    * `FLY_APP_NAME` — Fly app name (default: `"agent-os"`)
    * `FLY_REGION` — Fly region for new machines (default: `"iad"`)
    * `FLY_IMAGE` — Docker image for agent machines
      (default: `"registry.fly.io/agent-os:latest"`)

  ## Machine Lifecycle

  Each agent maps to one Fly Machine. The machine runs the agent-os Docker image
  with environment variables that configure which agent type to start. The health
  check endpoint is `GET /api/v1/health` on port 4000.

  ## Networking

  Machines expose port 4000 via Fly's internal DNS. The deployment URL follows
  the pattern `http://{machine_id}.vm.{app_name}.internal:4000`.
  """

  @behaviour AgentOS.Providers.Provider

  require Logger

  @api_base "https://api.machines.dev/v1"
  @default_app "agent-os"
  @default_region "iad"
  @default_image "registry.fly.io/agent-os:latest"

  # -- Provider Callbacks --

  @doc """
  Creates a new Fly Machine for the agent.

  Provisions a machine with shared-cpu-1x and 256MB RAM by default. The agent
  type and name are passed as environment variables to the container.
  """
  @impl true
  @spec create_agent(AgentOS.Providers.Provider.agent_config()) ::
          {:ok, AgentOS.Providers.Provider.deployment()} | {:error, term()}
  def create_agent(config) do
    app = app_name()
    image = image_name()
    region = region()

    resources = Map.get(config, :resources, %{})

    body = %{
      name: config.name,
      region: region,
      config: %{
        image: image,
        env:
          Map.merge(
            %{
              "AGENT_TYPE" => to_string(config.type),
              "AGENT_NAME" => config.name,
              "AGENT_OVERSIGHT" => to_string(Map.get(config, :oversight, :autonomous_escalation)),
              "AGENT_OS_PORT" => "4000"
            },
            stringify_env(Map.get(config, :env, %{}))
          ),
        guest: %{
          cpu_kind: "shared",
          cpus: Map.get(resources, :cpus, 1),
          memory_mb: Map.get(resources, :memory_mb, 256)
        },
        services: [
          %{
            ports: [%{port: 443, handlers: ["tls", "http"]}],
            protocol: "tcp",
            internal_port: 4000,
            checks: [
              %{
                type: "http",
                port: 4000,
                method: "GET",
                path: "/api/v1/health",
                interval: "15s",
                timeout: "5s"
              }
            ]
          }
        ],
        auto_destroy: true,
        restart: %{policy: "on-failure", max_retries: 3}
      }
    }

    case api_request(:post, "/apps/#{app}/machines", body) do
      {:ok, %{"id" => machine_id} = response} ->
        deployment = %{
          id: machine_id,
          provider: :fly,
          status: parse_status(Map.get(response, "state", "created")),
          url: "https://#{machine_id}.vm.#{app}.internal:4000",
          created_at: DateTime.utc_now()
        }

        Logger.info("Fly provider: created machine #{machine_id} in #{region} (image: #{image})")
        {:ok, deployment}

      {:error, reason} ->
        Logger.error("Fly provider: failed to create machine: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Starts a Fly Machine that was previously stopped or just created.
  """
  @impl true
  @spec start_agent(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_agent(deployment_id, _job_spec) do
    app = app_name()

    case api_request(:post, "/apps/#{app}/machines/#{deployment_id}/start", nil) do
      {:ok, _response} ->
        Logger.info("Fly provider: started machine #{deployment_id}")
        status(deployment_id)

      {:error, reason} ->
        Logger.error("Fly provider: failed to start machine #{deployment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops a running Fly Machine.
  """
  @impl true
  @spec stop_agent(String.t()) :: :ok | {:error, term()}
  def stop_agent(deployment_id) do
    app = app_name()

    case api_request(:post, "/apps/#{app}/machines/#{deployment_id}/stop", nil) do
      {:ok, _response} ->
        Logger.info("Fly provider: stopped machine #{deployment_id}")
        :ok

      {:error, reason} ->
        Logger.error("Fly provider: failed to stop machine #{deployment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetches the current status of a Fly Machine.
  """
  @impl true
  @spec status(String.t()) :: {:ok, AgentOS.Providers.Provider.deployment()} | {:error, term()}
  def status(deployment_id) do
    app = app_name()

    case api_request(:get, "/apps/#{app}/machines/#{deployment_id}", nil) do
      {:ok, %{"id" => id, "state" => state} = response} ->
        deployment = %{
          id: id,
          provider: :fly,
          status: parse_status(state),
          url: "https://#{id}.vm.#{app}.internal:4000",
          created_at: parse_datetime(Map.get(response, "created_at"))
        }

        {:ok, deployment}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves logs from a Fly Machine.

  Uses the Fly Machines ndjson log endpoint.
  """
  @impl true
  @spec logs(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def logs(deployment_id, _opts \\ []) do
    app = app_name()

    case api_request(:get, "/apps/#{app}/machines/#{deployment_id}/logs", nil) do
      {:ok, lines} when is_list(lines) ->
        {:ok, Enum.map(lines, &format_log_line/1)}

      {:ok, %{"lines" => lines}} ->
        {:ok, Enum.map(lines, &format_log_line/1)}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all Fly Machines in the configured app.
  """
  @impl true
  @spec list_agents() :: {:ok, [AgentOS.Providers.Provider.deployment()]}
  def list_agents do
    app = app_name()

    case api_request(:get, "/apps/#{app}/machines", nil) do
      {:ok, machines} when is_list(machines) ->
        deployments =
          Enum.map(machines, fn machine ->
            %{
              id: Map.get(machine, "id"),
              provider: :fly,
              status: parse_status(Map.get(machine, "state", "unknown")),
              url: "https://#{Map.get(machine, "id")}.vm.#{app}.internal:4000",
              created_at: parse_datetime(Map.get(machine, "created_at"))
            }
          end)

        {:ok, deployments}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Destroys a Fly Machine permanently with force flag.
  """
  @impl true
  @spec destroy_agent(String.t()) :: :ok | {:error, term()}
  def destroy_agent(deployment_id) do
    app = app_name()

    case api_request(:delete, "/apps/#{app}/machines/#{deployment_id}?force=true", nil) do
      {:ok, _response} ->
        Logger.info("Fly provider: destroyed machine #{deployment_id}")
        :ok

      {:error, reason} ->
        Logger.error("Fly provider: failed to destroy machine #{deployment_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Private Helpers --

  @spec api_request(atom(), String.t(), map() | nil) :: {:ok, term()} | {:error, term()}
  defp api_request(method, path, body) do
    url = @api_base <> path
    token = api_token()

    unless token do
      {:error, :missing_fly_api_token}
    else
      headers = [
        {~c"authorization", ~c"Bearer #{token}"},
        {~c"content-type", ~c"application/json"},
        {~c"accept", ~c"application/json"}
      ]

      :ok = ensure_httpc_started()

      request =
        case {method, body} do
          {:get, _} ->
            {String.to_charlist(url), headers}

          {:delete, _} ->
            {String.to_charlist(url), headers}

          {_, nil} ->
            {String.to_charlist(url), headers, ~c"application/json", ~c""}

          {_, body} ->
            encoded = Jason.encode!(body)
            {String.to_charlist(url), headers, ~c"application/json", String.to_charlist(encoded)}
        end

      http_method =
        case method do
          :get -> :get
          :post -> :post
          :delete -> :delete
        end

      case :httpc.request(http_method, request, [{:timeout, 30_000}], []) do
        {:ok, {{_, status_code, _}, _headers, response_body}} when status_code in 200..299 ->
          case Jason.decode(to_string(response_body)) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:ok, to_string(response_body)}
          end

        {:ok, {{_, status_code, _}, _headers, response_body}} ->
          Logger.error("Fly API #{method} #{path} returned #{status_code}: #{to_string(response_body)}")
          {:error, {:http_error, status_code, to_string(response_body)}}

        {:error, reason} ->
          Logger.error("Fly API #{method} #{path} request failed: #{inspect(reason)}")
          {:error, {:request_failed, reason}}
      end
    end
  end

  @spec ensure_httpc_started() :: :ok
  defp ensure_httpc_started do
    case :inets.start(:httpc, profile: :fly_provider) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @spec api_token() :: String.t() | nil
  defp api_token, do: System.get_env("FLY_API_TOKEN")

  @spec app_name() :: String.t()
  defp app_name, do: System.get_env("FLY_APP_NAME") || @default_app

  @spec region() :: String.t()
  defp region, do: System.get_env("FLY_REGION") || @default_region

  @spec image_name() :: String.t()
  defp image_name, do: System.get_env("FLY_IMAGE") || @default_image

  @spec parse_status(String.t()) :: :pending | :running | :stopped | :failed
  defp parse_status("started"), do: :running
  defp parse_status("running"), do: :running
  defp parse_status("stopped"), do: :stopped
  defp parse_status("destroyed"), do: :stopped
  defp parse_status("created"), do: :pending
  defp parse_status("failed"), do: :failed
  defp parse_status(_), do: :pending

  @spec parse_datetime(String.t() | nil) :: DateTime.t()
  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  @spec stringify_env(map()) :: map()
  defp stringify_env(env) do
    Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  @spec format_log_line(map() | String.t()) :: String.t()
  defp format_log_line(line) when is_binary(line), do: line

  defp format_log_line(%{"message" => msg, "timestamp" => ts}) do
    "[#{ts}] #{msg}"
  end

  defp format_log_line(%{"message" => msg}), do: msg
  defp format_log_line(line), do: inspect(line)
end
