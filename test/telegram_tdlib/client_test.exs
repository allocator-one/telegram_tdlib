defmodule TelegramTdlib.ClientTest.FakeTransport do
  @moduledoc """
  A stand-in for `TelegramTdlib.Port` that lets tests observe outgoing requests
  and inject responses, without a real TDLib process. Implements the transport
  contract `Client` depends on: `start_link/1` (accepting `:owner`) and `send/2`.

  Outgoing requests are forwarded to the `:test_pid` as `{:sent, request}`, and
  the transport announces its own pid as `{:transport_up, pid}` so lifecycle
  tests can stop it.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def send(server, %{} = request), do: GenServer.cast(server, {:send, request})

  @impl true
  def init(opts) do
    test = Keyword.fetch!(opts, :test_pid)
    Kernel.send(test, {:transport_up, self()})
    {:ok, %{test: test}}
  end

  @impl true
  def handle_cast({:send, request}, state) do
    Kernel.send(state.test, {:sent, request})
    {:noreply, state}
  end
end

defmodule TelegramTdlib.ClientTest do
  use ExUnit.Case, async: true

  alias TelegramTdlib.Client
  alias TelegramTdlib.ClientTest.FakeTransport

  setup do
    # handler defaults to the caller (this test process).
    {:ok, client} = Client.start_link(transport: FakeTransport, test_pid: self())
    assert_receive {:transport_up, transport}
    %{client: client, transport: transport}
  end

  describe "request/4 correlation" do
    test "matches a response by @extra and returns {:ok, msg}", %{client: client} do
      task = Task.async(fn -> Client.request(client, "getMe") end)
      assert_receive {:sent, %{"@type" => "getMe", "@extra" => token}}
      Kernel.send(client, {:tdlib, %{"@type" => "user", "id" => 7, "@extra" => token}})
      assert {:ok, %{"@type" => "user", "id" => 7}} = Task.await(task)
    end

    test "classifies an error object as {:error, msg}", %{client: client} do
      task = Task.async(fn -> Client.request(client, "getMe") end)
      assert_receive {:sent, %{"@extra" => token}}

      Kernel.send(
        client,
        {:tdlib, %{"@type" => "error", "code" => 400, "message" => "nope", "@extra" => token}}
      )

      assert {:error, %{"@type" => "error", "code" => 400}} = Task.await(task)
    end

    test "tracks concurrent requests independently, replying out of order", %{client: client} do
      t1 = Task.async(fn -> Client.request(client, "a") end)
      assert_receive {:sent, %{"@type" => "a", "@extra" => tok1}}
      t2 = Task.async(fn -> Client.request(client, "b") end)
      assert_receive {:sent, %{"@type" => "b", "@extra" => tok2}}
      refute tok1 == tok2

      Kernel.send(client, {:tdlib, %{"@type" => "ok", "which" => "b", "@extra" => tok2}})
      Kernel.send(client, {:tdlib, %{"@type" => "ok", "which" => "a", "@extra" => tok1}})

      assert {:ok, %{"which" => "b"}} = Task.await(t2)
      assert {:ok, %{"which" => "a"}} = Task.await(t1)
    end
  end

  describe "update delivery" do
    test "unsolicited updates (no @extra) reach the handler", %{client: client} do
      Kernel.send(client, {:tdlib, %{"@type" => "updateNewMessage", "message" => %{"id" => 1}}})
      assert_receive {:tdlib_update, %{"@type" => "updateNewMessage"}}
    end

    test "a response with an unknown @extra is delivered as an update", %{client: client} do
      Kernel.send(client, {:tdlib, %{"@type" => "user", "@extra" => "stale-token"}})
      assert_receive {:tdlib_update, %{"@type" => "user", "@extra" => "stale-token"}}
    end

    test "the shim bootstrap response is dropped, not surfaced", %{client: client} do
      Kernel.send(client, {:tdlib, %{"@type" => "optionValueString", "@extra" => "bootstrap"}})
      refute_receive {:tdlib_update, _}, 100
    end
  end

  test "cast/3 forwards a request without an @extra token", %{client: client} do
    Client.cast(client, "setLogVerbosityLevel", %{"new_verbosity_level" => 2})
    assert_receive {:sent, request}
    assert request["@type"] == "setLogVerbosityLevel"
    refute Map.has_key?(request, "@extra")
  end

  test "in-flight requests get an error reply when the transport goes down", %{
    client: client,
    transport: transport
  } do
    task = Task.async(fn -> Client.request(client, "getMe", %{}, 2000) end)
    assert_receive {:sent, %{"@extra" => _token}}
    GenServer.stop(transport, :normal)
    assert {:error, %{"reason" => "transport_down"}} = Task.await(task)
  end
end
