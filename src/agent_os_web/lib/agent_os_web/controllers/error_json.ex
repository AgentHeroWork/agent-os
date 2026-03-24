defmodule AgentOS.Web.ErrorJSON do
  @moduledoc """
  JSON error responses for Phoenix error handling.

  Renders structured JSON error bodies for common HTTP status codes.
  Used by the Phoenix endpoint's `render_errors` configuration.
  """

  def render("404.json", _assigns) do
    %{error: "not_found"}
  end

  def render("500.json", _assigns) do
    %{error: "internal_server_error"}
  end

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
