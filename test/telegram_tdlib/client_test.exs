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

  def send(server, %{} = request), do: GenServer.call(server, {:send, request})

  @impl true
  def init(opts) do
    test = Keyword.fetch!(opts, :test_pid)
    Kernel.send(test, {:transport_up, self()})
    {:ok, %{test: test, fail_send: Keyword.get(opts, :fail_send, false)}}
  end

  @impl true
  def handle_call({:send, request}, _from, state) do
    Kernel.send(state.test, {:sent, request})
    reply = if state.fail_send, do: {:error, :boom}, else: :ok
    {:reply, reply, state}
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
    test "matches a response by @extra and returns {:ok, msg} with @extra stripped", %{
      client: client
    } do
      task = Task.async(fn -> Client.request(client, "getMe") end)
      assert_receive {:sent, %{"@type" => "getMe", "@extra" => token}}
      Kernel.send(client, {:tdlib, %{"@type" => "user", "id" => 7, "@extra" => token}})
      assert {:ok, %{"@type" => "user", "id" => 7} = result} = Task.await(task)
      refute Map.has_key?(result, "@extra")
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

    test "a response with an unknown @extra is delivered as an update, @extra stripped", %{
      client: client
    } do
      Kernel.send(client, {:tdlib, %{"@type" => "user", "@extra" => "stale-token"}})
      assert_receive {:tdlib_update, %{"@type" => "user"} = update}
      refute Map.has_key?(update, "@extra")
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
    ref = Process.monitor(client)
    task = Task.async(fn -> Client.request(client, "getMe", %{}, 2000) end)
    assert_receive {:sent, %{"@extra" => _token}}
    GenServer.stop(transport, :normal)
    assert {:error, %{"@type" => "error", "message" => "transport_down"}} = Task.await(task)
    # The client then stops with the transport's exit reason, as documented.
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}
  end

  test "a request fails fast (no hang) when the transport rejects the send" do
    {:ok, client} = Client.start_link(transport: FakeTransport, test_pid: self(), fail_send: true)
    assert_receive {:transport_up, _transport}

    # A short timeout proves the reply is immediate, not a timeout expiry.
    assert {:error, %{"@type" => "error", "message" => "transport_down"}} =
             Client.request(client, "getMe", %{}, 500)
  end

  @tag :capture_log
  test "the client stops (tagged) when its handler process dies" do
    handler = spawn(fn -> receive(do: (_ -> :ok)) end)

    {:ok, client} =
      Client.start_link(transport: FakeTransport, test_pid: self(), handler: handler)

    # Unlink so the client's abnormal exit doesn't take the test down with it.
    Process.unlink(client)
    assert_receive {:transport_up, _transport}

    ref = Process.monitor(client)
    Process.exit(handler, :kill)
    assert_receive {:DOWN, ^ref, :process, ^client, {:handler_down, :killed}}
  end
end
