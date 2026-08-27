defmodule Auth0.Common.Management.TokenManagerTest do
  use ExUnit.Case

  alias Auth0.Common.Management.TokenManager.Store

  @registry :tokens_registry

  setup do
    delete_registry()
    on_exit(&delete_registry/0)
    :ok
  end

  describe "init/0" do
    test "is idempotent when the registry table already exists" do
      assert :ok = Store.init()
      assert :ok = Store.init()
      assert :ets.whereis(@registry) != :undefined
    end

    test "does not raise when another live process already owns the table" do
      owner = spawn_registry_owner()

      assert :ok = Store.init()
      assert :ets.info(@registry, :owner) == owner
    end
  end

  describe "put/2 and get/1" do
    test "create the table on first use" do
      assert :ets.whereis(@registry) == :undefined

      assert :ok = Store.put("client-id", {"token", 123})
      assert {"token", 123} = Store.get("client-id")
    end

    test "succeed from a process that does not own the table" do
      owner = spawn_registry_owner()
      assert :ets.info(@registry, :owner) == owner

      assert :ok = Store.put("client-id", {"token", 123})
      assert {"token", 123} = Store.get("client-id")
    end
  end

  # Creates the registry from a separate, still-running process so the test
  # process is a non-owner for the duration of the test. Linked, so the table
  # goes away with the test process.
  defp spawn_registry_owner() do
    test = self()

    owner =
      spawn_link(fn ->
        :ok = Store.init()
        send(test, :registry_created)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registry_created
    owner
  end

  defp delete_registry() do
    case :ets.whereis(@registry) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    :ok
  end
end
