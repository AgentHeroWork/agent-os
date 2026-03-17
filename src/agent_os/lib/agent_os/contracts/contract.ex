defmodule AgentOS.Contracts.Contract do
  @moduledoc """
  Behaviour defining an agent execution contract.

  A contract validates WHAT an agent produces, not HOW it produces it.
  Agents own their execution pipeline; contracts only specify required
  artifacts, verification logic, and retry policy.
  """

  @callback required_artifacts() :: [atom()]
  @callback verify(artifacts :: map()) :: :ok | {:retry, String.t()}
  @callback max_retries() :: non_neg_integer()
end
