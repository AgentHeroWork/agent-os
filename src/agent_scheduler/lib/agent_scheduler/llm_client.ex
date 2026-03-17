defmodule AgentScheduler.LLMClient do
  @moduledoc """
  LLM API client supporting OpenAI, Anthropic, and Ollama.

  Uses :httpc (no external deps) to call chat completion endpoints.

  Config resolution order:
    1. Explicit opts (api_key, base_url, model)
    2. OPENAI_API_KEY / ANTHROPIC_API_KEY env vars
    3. OLLAMA_HOST env var (default: http://localhost:11434)
  """

  require Logger

  @default_model "gpt-4o"
  @default_max_tokens 4096
  @default_temperature 0.7
  @openai_base "https://api.openai.com"
  @anthropic_base "https://api.anthropic.com"
  @ollama_base "http://localhost:11434"
  @anthropic_version "2023-06-01"

  @type message :: %{role: String.t(), content: String.t()}

  @doc """
  Send a chat completion request to an LLM provider.

  ## Options
    * `:model` — Model name (default: "gpt-4o")
    * `:temperature` — Sampling temperature (default: 0.7)
    * `:max_tokens` — Max response tokens (default: 4096)
    * `:api_key` — API key (overrides env var)
    * `:base_url` — Base URL (overrides provider default)
    * `:provider` — :openai | :anthropic | :ollama (auto-detected from api_key if omitted)
  """
  @spec chat([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) do
    ensure_httpc_started()

    provider = resolve_provider(opts)
    api_key = resolve_api_key(provider, opts)

    case provider do
      :anthropic -> chat_anthropic(messages, api_key, opts)
      :ollama -> chat_ollama(messages, opts)
      :openai -> chat_openai(messages, api_key, opts)
    end
  end

  # -- OpenAI-compatible --

  defp chat_openai(messages, api_key, opts) do
    base_url = Keyword.get(opts, :base_url, @openai_base)
    url = "#{base_url}/v1/chat/completions"

    body =
      Jason.encode!(%{
        model: Keyword.get(opts, :model, @default_model),
        messages: format_messages(messages),
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)
      })

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"authorization", ~c"Bearer #{api_key}"}
    ]

    do_request(url, headers, body)
    |> parse_openai_response()
  end

  # -- Anthropic --

  defp chat_anthropic(messages, api_key, opts) do
    base_url = Keyword.get(opts, :base_url, @anthropic_base)
    url = "#{base_url}/v1/messages"

    {system_msg, user_messages} = extract_system(messages)

    body =
      Jason.encode!(
        %{
          model: Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
          max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
          messages: format_messages(user_messages)
        }
        |> maybe_put_system(system_msg)
      )

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-api-key", ~c"#{api_key}"},
      {~c"anthropic-version", ~c"#{@anthropic_version}"}
    ]

    do_request(url, headers, body)
    |> parse_anthropic_response()
  end

  # -- Ollama --

  defp chat_ollama(messages, opts) do
    base_url = Keyword.get(opts, :base_url, System.get_env("OLLAMA_HOST") || @ollama_base)
    url = "#{base_url}/api/chat"

    body =
      Jason.encode!(%{
        model: Keyword.get(opts, :model, "llama3"),
        messages: format_messages(messages),
        stream: false,
        options: %{
          temperature: Keyword.get(opts, :temperature, @default_temperature)
        }
      })

    headers = [{~c"content-type", ~c"application/json"}]

    do_request(url, headers, body)
    |> parse_ollama_response()
  end

  # -- HTTP --

  defp do_request(url, headers, body) do
    url_charlist = String.to_charlist(url)

    case :httpc.request(
           :post,
           {url_charlist, headers, ~c"application/json", body},
           [timeout: 120_000, connect_timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:ok, status, resp_body}

      {:error, reason} ->
        Logger.error("LLM HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  # -- Response Parsers --

  defp parse_openai_response({:ok, status, body}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        {:ok, content}

      {:ok, decoded} ->
        {:error, {:unexpected_response, decoded}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_openai_response({:ok, status, body}) do
    Logger.error("OpenAI API error #{status}: #{String.slice(to_string(body), 0, 500)}")
    {:error, {:api_error, status, body}}
  end

  defp parse_openai_response({:error, _} = err), do: err

  defp parse_anthropic_response({:ok, status, body}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"content" => [%{"text" => text} | _]}} ->
        {:ok, text}

      {:ok, decoded} ->
        {:error, {:unexpected_response, decoded}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_anthropic_response({:ok, status, body}) do
    Logger.error("Anthropic API error #{status}: #{String.slice(to_string(body), 0, 500)}")
    {:error, {:api_error, status, body}}
  end

  defp parse_anthropic_response({:error, _} = err), do: err

  defp parse_ollama_response({:ok, status, body}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"message" => %{"content" => content}}} ->
        {:ok, content}

      {:ok, decoded} ->
        {:error, {:unexpected_response, decoded}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_ollama_response({:ok, status, body}) do
    Logger.error("Ollama API error #{status}: #{String.slice(to_string(body), 0, 500)}")
    {:error, {:api_error, status, body}}
  end

  defp parse_ollama_response({:error, _} = err), do: err

  # -- Helpers --

  defp resolve_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        cond do
          Keyword.get(opts, :api_key) && String.starts_with?(Keyword.get(opts, :api_key, ""), "sk-ant-") ->
            :anthropic

          System.get_env("ANTHROPIC_API_KEY") && !System.get_env("OPENAI_API_KEY") ->
            :anthropic

          System.get_env("OPENAI_API_KEY") ->
            :openai

          true ->
            :ollama
        end

      provider ->
        provider
    end
  end

  defp resolve_api_key(:openai, opts) do
    Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")
  end

  defp resolve_api_key(:anthropic, opts) do
    Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")
  end

  defp resolve_api_key(:ollama, _opts), do: nil

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg[:role] || msg["role"] || "user"),
        "content" => to_string(msg[:content] || msg["content"] || "")
      }
    end)
  end

  defp extract_system(messages) do
    case Enum.split_with(messages, fn m ->
           role = m[:role] || m["role"]
           to_string(role) == "system"
         end) do
      {[], rest} -> {nil, rest}
      {[sys | _], rest} -> {sys[:content] || sys["content"], rest}
    end
  end

  defp maybe_put_system(body, nil), do: body
  defp maybe_put_system(body, system), do: Map.put(body, :system, system)

  defp ensure_httpc_started do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
    end

    case :ssl.start() do
      :ok -> :ok
      {:error, {:already_started, :ssl}} -> :ok
    end
  end
end
