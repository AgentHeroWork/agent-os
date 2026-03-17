defmodule AgentOS.CredentialsTest do
  use ExUnit.Case, async: true

  alias AgentOS.Credentials

  describe "resolve/1" do
    test "reads from environment variables" do
      System.put_env("GITHUB_TOKEN", "ghp_test_env_token")
      System.put_env("FLY_API_TOKEN", "fly_test_token")

      on_exit(fn ->
        System.delete_env("GITHUB_TOKEN")
        System.delete_env("FLY_API_TOKEN")
      end)

      result = Credentials.resolve()

      assert result.github_token == "ghp_test_env_token"
      assert result.fly_api_token == "fly_test_token"
    end

    test "explicit credentials override env vars" do
      System.put_env("GITHUB_TOKEN", "ghp_from_env")

      on_exit(fn ->
        System.delete_env("GITHUB_TOKEN")
      end)

      result = Credentials.resolve(%{github_token: "ghp_explicit"})

      assert result.github_token == "ghp_explicit"
    end
  end

  describe "github_token/1" do
    test "with explicit token returns it" do
      assert Credentials.github_token(%{github_token: "ghp_my_token"}) == "ghp_my_token"
    end

    test "falls back to env var" do
      System.put_env("GITHUB_TOKEN", "ghp_env_token")

      on_exit(fn ->
        System.delete_env("GITHUB_TOKEN")
      end)

      assert Credentials.github_token(%{}) == "ghp_env_token"
    end

    test "falls back to gh CLI when no env var" do
      System.delete_env("GITHUB_TOKEN")

      # gh CLI may or may not be available; just ensure no crash
      result = Credentials.github_token(%{})
      assert is_binary(result) or is_nil(result)
    end
  end

  describe "validate_for_agent/2" do
    test "returns :ok when required creds are present" do
      creds = %{github_token: "ghp_test", agent_os_api_key: nil, fly_api_token: nil, custom: %{}}
      assert Credentials.validate_for_agent(:open_claw, creds) == :ok
    end

    test "returns error with missing credential names" do
      creds = %{github_token: nil, agent_os_api_key: nil, fly_api_token: nil, custom: %{}}
      assert {:error, [:github_token]} = Credentials.validate_for_agent(:open_claw, creds)
    end

    test "returns :ok for unknown agent type with no requirements" do
      creds = %{github_token: nil, agent_os_api_key: nil, fly_api_token: nil, custom: %{}}
      assert Credentials.validate_for_agent(:some_other, creds) == :ok
    end
  end

  describe "sanitize/1" do
    test "masks token values" do
      creds = %{
        github_token: "ghp_abcdef123456789",
        agent_os_api_key: "sk_longapikey1234",
        fly_api_token: nil,
        custom: %{"service" => "key_my_secret_value"}
      }

      sanitized = Credentials.sanitize(creds)

      assert sanitized.github_token =~ "****"
      refute sanitized.github_token == creds.github_token
      assert sanitized.agent_os_api_key =~ "****"
      assert sanitized.fly_api_token == nil
      assert sanitized.custom["service"] =~ "****"
    end

    test "masks short tokens completely" do
      creds = %{github_token: "short", agent_os_api_key: nil, fly_api_token: nil, custom: %{}}
      sanitized = Credentials.sanitize(creds)
      assert sanitized.github_token == "****"
    end
  end
end
