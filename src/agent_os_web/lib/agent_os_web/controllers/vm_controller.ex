defmodule AgentOS.Web.Controllers.VMController do
  @moduledoc """
  Proxy endpoints for agents running inside microVMs.

  microVM agents call these endpoints to access services on the host
  that require secrets (LLM API keys) or shared state (memory).
  API keys never enter the VM — the proxy makes the call on behalf of the agent.
  """

  import Plug.Conn

  require Logger

  @doc """
  Proxies an LLM chat request from a microVM agent.

  The agent sends messages + model config. This controller calls
  AgentScheduler.LLMClient.chat/2 with the real API key from the
  host environment. Returns the LLM response to the agent.

  Expected body: {"messages": [...], "model": "gpt-4o", "max_tokens": 4096}
  Returns: {"content": "..."} or {"error": "..."}
  """
  def llm_chat(conn) do
    body = conn.body_params

    messages =
      (body["messages"] || [])
      |> Enum.map(fn msg ->
        %{role: msg["role"] || "user", content: msg["content"] || ""}
      end)

    if messages == [] do
      json_resp(conn, 400, %{error: "messages required"})
    else
      opts =
        []
        |> maybe_add(:model, body["model"])
        |> maybe_add(:max_tokens, body["max_tokens"])
        |> maybe_add(:temperature, body["temperature"])

      Logger.info("VMController: LLM proxy request (#{length(messages)} messages, model: #{body["model"] || "default"})")

      case AgentScheduler.LLMClient.chat(messages, opts) do
        {:ok, content} ->
          json_resp(conn, 200, %{content: content})

        {:error, reason} ->
          Logger.error("VMController: LLM proxy failed — #{inspect(reason)}")
          json_resp(conn, 502, %{error: "llm_request_failed", detail: inspect(reason)})
      end
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, val), do: Keyword.put(opts, key, val)

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
