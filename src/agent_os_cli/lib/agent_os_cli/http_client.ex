defmodule AgentOS.CLI.HttpClient do
  @moduledoc """
  HTTP client for CLI commands. Uses Erlang's :httpc.

  Resolves the API host from:
  1. `opts[:host]` (--host flag)
  2. `AGENT_OS_HOST` env var
  3. Default: `"http://localhost:4000"`

  Includes API key in Authorization header if set via `opts[:api_key]`,
  `--api-key` flag, or `AGENT_OS_API_KEY` env var.
  """

  @doc """
  Sends a GET request to the given path.

  Returns `{:ok, decoded_body}` on success or `{:error, reason}` on failure.
  """
  def get(path, opts) do
    ensure_started()
    url = build_url(path, opts)
    headers = build_headers(opts)

    case :httpc.request(:get, {url, headers}, http_opts(), []) do
      {:ok, {{_, status, _}, _resp_headers, body}} when status >= 200 and status < 300 ->
        decode_body(body)

      {:ok, {{_, status, reason_phrase}, _resp_headers, body}} ->
        {:error, {:http, status, to_string(reason_phrase), to_string(body)}}

      {:error, reason} ->
        {:error, {:connection, reason}}
    end
  end

  @doc """
  Sends a POST request with a JSON body to the given path.

  Returns `{:ok, decoded_body}` on success or `{:error, reason}` on failure.
  """
  def post(path, body_map, opts) do
    ensure_started()
    url = build_url(path, opts)
    headers = build_headers(opts)
    json_body = Jason.encode!(body_map)
    content_type = ~c"application/json"

    case :httpc.request(:post, {url, headers, content_type, json_body}, http_opts(), []) do
      {:ok, {{_, status, _}, _resp_headers, body}} when status >= 200 and status < 300 ->
        decode_body(body)

      {:ok, {{_, status, reason_phrase}, _resp_headers, body}} ->
        {:error, {:http, status, to_string(reason_phrase), to_string(body)}}

      {:error, reason} ->
        {:error, {:connection, reason}}
    end
  end

  @doc """
  Sends a DELETE request to the given path.

  Returns `{:ok, decoded_body}` on success or `{:error, reason}` on failure.
  """
  def delete(path, opts) do
    ensure_started()
    url = build_url(path, opts)
    headers = build_headers(opts)

    case :httpc.request(:delete, {url, headers}, http_opts(), []) do
      {:ok, {{_, status, _}, _resp_headers, body}} when status >= 200 and status < 300 ->
        decode_body(body)

      {:ok, {{_, status, reason_phrase}, _resp_headers, body}} ->
        {:error, {:http, status, to_string(reason_phrase), to_string(body)}}

      {:error, reason} ->
        {:error, {:connection, reason}}
    end
  end

  # --- Private helpers ---

  defp ensure_started do
    :inets.start()
    :ssl.start()
  end

  defp build_url(path, opts) do
    host = opts[:host] || System.get_env("AGENT_OS_HOST", "http://localhost:4000")
    String.to_charlist(host <> path)
  end

  defp build_headers(opts) do
    api_key = opts[:api_key] || System.get_env("AGENT_OS_API_KEY")

    base = [{~c"accept", ~c"application/json"}]

    if api_key do
      [{~c"authorization", String.to_charlist("Bearer #{api_key}")} | base]
    else
      base
    end
  end

  defp http_opts do
    [timeout: 30_000, connect_timeout: 5_000]
  end

  defp decode_body(body) do
    body
    |> to_string()
    |> case do
      "" -> {:ok, %{}}
      str -> Jason.decode(str)
    end
  end
end
