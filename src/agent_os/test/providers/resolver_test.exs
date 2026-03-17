defmodule AgentOS.Providers.ResolverTest do
  use ExUnit.Case, async: true

  alias AgentOS.Providers.Resolver

  describe "resolve/0" do
    test "defaults to Local provider when no env var is set" do
      # Ensure env var is unset for this test
      original = System.get_env("AGENT_OS_TARGET")
      System.delete_env("AGENT_OS_TARGET")

      assert Resolver.resolve() == AgentOS.Providers.Local

      # Restore
      if original, do: System.put_env("AGENT_OS_TARGET", original)
    end
  end

  describe "resolve/1" do
    test "resolves :local to Local provider" do
      assert Resolver.resolve(:local) == AgentOS.Providers.Local
    end

    test "resolves :fly to Fly provider" do
      assert Resolver.resolve(:fly) == AgentOS.Providers.Fly
    end

    test "resolves nil to default (Local)" do
      original = System.get_env("AGENT_OS_TARGET")
      System.delete_env("AGENT_OS_TARGET")

      assert Resolver.resolve(nil) == AgentOS.Providers.Local

      if original, do: System.put_env("AGENT_OS_TARGET", original)
    end

    test "resolves unknown provider to Local as fallback" do
      assert Resolver.resolve(:unknown_provider) == AgentOS.Providers.Local
    end
  end

  describe "resolve_from_env/0" do
    test "resolves from AGENT_OS_TARGET env var" do
      original = System.get_env("AGENT_OS_TARGET")

      System.put_env("AGENT_OS_TARGET", "fly")
      assert Resolver.resolve_from_env() == AgentOS.Providers.Fly

      System.put_env("AGENT_OS_TARGET", "local")
      assert Resolver.resolve_from_env() == AgentOS.Providers.Local

      # Restore
      if original do
        System.put_env("AGENT_OS_TARGET", original)
      else
        System.delete_env("AGENT_OS_TARGET")
      end
    end

    test "falls back to Local for unrecognized AGENT_OS_TARGET" do
      original = System.get_env("AGENT_OS_TARGET")

      System.put_env("AGENT_OS_TARGET", "some_unknown_target")
      assert Resolver.resolve_from_env() == AgentOS.Providers.Local

      if original do
        System.put_env("AGENT_OS_TARGET", original)
      else
        System.delete_env("AGENT_OS_TARGET")
      end
    end

    test "returns Local when AGENT_OS_TARGET is not set" do
      original = System.get_env("AGENT_OS_TARGET")
      System.delete_env("AGENT_OS_TARGET")

      assert Resolver.resolve_from_env() == AgentOS.Providers.Local

      if original, do: System.put_env("AGENT_OS_TARGET", original)
    end
  end

  describe "available_providers/0" do
    test "returns a list of provider tuples" do
      providers = Resolver.available_providers()

      assert is_list(providers)
      assert {:local, AgentOS.Providers.Local} in providers
      assert {:fly, AgentOS.Providers.Fly} in providers
    end

    test "list is sorted by provider name" do
      providers = Resolver.available_providers()
      names = Enum.map(providers, fn {name, _} -> name end)

      assert names == Enum.sort(names)
    end
  end
end
