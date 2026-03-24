defmodule AgentOS.Web.Controllers.JobController do
  @moduledoc """
  REST controller for job submission and status retrieval.

  Jobs are submitted to the `AgentScheduler` pipeline where they flow through
  scheduling, agent assignment, execution, and evaluation.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  @doc """
  Submits a new job to the scheduling pipeline.

  Expects JSON body with `client_id`, `task`, and `input`.
  Returns 201 with the assigned job ID on success.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    body = conn.body_params

    with {:ok, client_id} <- require_param(body, "client_id"),
         {:ok, task} <- require_param(body, "task"),
         {:ok, input} <- require_param(body, "input") do
      job = %{
        task: String.to_atom(task),
        input: input,
        oversight: parse_oversight(body["oversight"])
      }

      opts =
        []
        |> maybe_add(:timeout, body["timeout"])
        |> maybe_add(:max_retries, body["max_retries"])

      case AgentScheduler.submit_job(client_id, job, opts) do
        {:ok, job_id} ->
          json_resp(conn, 201, %{job_id: job_id, status: "submitted"})

        {:error, reason} ->
          json_resp(conn, 500, %{error: "submission_failed", detail: inspect(reason)})
      end
    else
      {:error, msg} ->
        json_resp(conn, 400, %{error: msg})
    end
  end

  @doc """
  Shows the status of a job by ID.

  Looks up the job in the ETS-based `AgentOS.JobTracker` registry.
  Returns 404 if the job ID is not found.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case AgentOS.JobTracker.get(id) do
      {:ok, job} ->
        json_resp(conn, 200, %{job_id: job.id, status: job.status, created_at: job.created_at})

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "job_not_found", job_id: id})
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp require_param(body, key) do
    case body[key] do
      nil -> {:error, "missing required field: #{key}"}
      val -> {:ok, val}
    end
  end

  defp parse_oversight(nil), do: :autonomous_escalation
  defp parse_oversight("autonomous"), do: :autonomous
  defp parse_oversight("autonomous_escalation"), do: :autonomous_escalation
  defp parse_oversight("supervised"), do: :supervised
  defp parse_oversight("human_in_loop"), do: :human_in_loop
  defp parse_oversight(_), do: :autonomous_escalation

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, val) when is_integer(val), do: [{key, val} | opts]
  defp maybe_add(opts, _key, _val), do: opts

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
