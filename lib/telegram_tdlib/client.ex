defmodule TelegramTdlib.Client do
  @moduledoc """
  A `GenServer` owning a single TDLib client (via a transport, by default
  `TelegramTdlib.Port`).

  Provides:

    * `request/4` — send a TDLib method and await its correlated response.
      Correlation uses TDLib's `@extra` field: a token is injected into the
      request and matched against the `@extra` echoed on the response.
    * `cast/3` — fire-and-forget a TDLib method.
    * update delivery — every unsolicited TDLib update (no matching pending
      request) is sent to the `:handler` pid as `{:tdlib_update, map}`.

  Methods are TDLib `@type` strings; params/responses are plain maps with string
  keys.

  ## Lifecycle

  The transport is started linked. `Client` traps exits so that if the transport
  (and thus the external shim) dies, every in-flight `request/4` caller receives
  a prompt `{:error, ...}` reply instead of blocking until its own timeout, and
  the client then stops with the transport's exit reason. Supervise `Client` to
  recover.

  ## Transport injection

  `:transport` defaults to `TelegramTdlib.Port`. Any module implementing
  `start_link/1` (accepting `:owner`) and `send/2` can be supplied — used by the
  test suite to exercise correlation without a real TDLib process. Options other
  than `:name`, `:transport`, and `:handler` are passed through to the
  transport's `start_link/1`.
  """
  use GenServer
  require Logger

  @default_timeout 10_000

  # The shim emits one internal bootstrap request to start TDLib's update loop;
  # its response carries this token and is neither an application reply nor an
  # update, so it is dropped.
  @bootstrap_token "bootstrap"

  # ---- API ----

  @doc """
  Start the client.

  Options:

    * `:handler` — pid to receive `{:tdlib_update, map}` updates. Defaults to the
      process calling `start_link/1`.
    * `:transport` — transport module (default `TelegramTdlib.Port`).
    * `:name` — optional GenServer name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # Resolve the handler to the CALLER's pid here, before the GenServer is
    # spawned — inside init/1, self() would be the GenServer itself.
    opts = Keyword.put_new(opts, :handler, self())
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Send a TDLib `method` (its `@type`) with `params` and await the response.

  Returns `{:ok, response_map}`, or `{:error, error_map}` when TDLib replies with
  an `error` object or the transport goes down with the request in flight.
  """
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, map()}
  def request(server, method, params \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(server, {:request, method, params}, timeout)
  end

  @doc "Fire-and-forget a TDLib `method` with `params`."
  @spec cast(GenServer.server(), String.t(), map()) :: :ok
  def cast(server, method, params \\ %{}) do
    GenServer.cast(server, {:cast, method, params})
  end

  # ---- Callbacks ----

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler = Keyword.fetch!(opts, :handler)
    # The client exists to serve its handler; if the handler dies, stop too
    # (a supervisor can restart with a fresh handler) rather than silently
    # dropping updates onto a dead pid.
    if is_pid(handler), do: Process.monitor(handler)
    transport = Keyword.get(opts, :transport, TelegramTdlib.Port)

    transport_opts =
      opts
      |> Keyword.drop([:name, :transport, :handler])
      |> Keyword.put(:owner, self())

    case transport.start_link(transport_opts) do
      {:ok, port} ->
        {:ok, %{transport: transport, port: port, handler: handler, pending: %{}, seq: 0}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    token = "req-" <> Integer.to_string(state.seq)
    state.transport.send(state.port, build(method, params, token))

    {:noreply, %{state | seq: state.seq + 1, pending: Map.put(state.pending, token, from)}}
  end

  @impl true
  def handle_cast({:cast, method, params}, state) do
    state.transport.send(state.port, build(method, params, nil))
    {:noreply, state}
  end

  @impl true
  def handle_info({:tdlib, %{"@extra" => @bootstrap_token}}, state) do
    {:noreply, state}
  end

  def handle_info({:tdlib, %{"@extra" => token} = msg}, state) do
    # @extra is our internal correlation token; strip it before it reaches
    # callers or the handler.
    clean = Map.delete(msg, "@extra")

    case Map.pop(state.pending, token) do
      {nil, _pending} ->
        dispatch_update(clean, state)
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, classify(clean))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:tdlib, msg}, state) do
    dispatch_update(msg, state)
    {:noreply, state}
  end

  # The linked transport (and thus the shim) died: fail in-flight requests now.
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    reply_all_pending(state.pending, transport_down_error())
    {:stop, reason, %{state | pending: %{}}}
  end

  # Any other linked process (e.g. the owner) exiting takes the client with it.
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  # The monitored handler died — there is no one left to serve.
  def handle_info({:DOWN, _ref, :process, handler, reason}, %{handler: handler} = state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    reply_all_pending(state.pending, transport_down_error())
    :ok
  end

  # ---- helpers ----

  defp build(method, params, token) do
    # Drop any caller-supplied @type/@extra so they can't shadow the method or
    # collide with our correlation token.
    base = params |> Map.new() |> Map.drop(["@type", "@extra"]) |> Map.put("@type", method)
    if token, do: Map.put(base, "@extra", token), else: base
  end

  defp classify(%{"@type" => "error"} = err), do: {:error, err}
  defp classify(msg), do: {:ok, msg}

  defp reply_all_pending(pending, reply) do
    Enum.each(pending, fn {_token, from} -> GenServer.reply(from, reply) end)
  end

  defp transport_down_error,
    do: {:error, %{"@type" => "error", "reason" => "transport_down"}}

  defp dispatch_update(msg, %{handler: handler}) when is_pid(handler) do
    Kernel.send(handler, {:tdlib_update, msg})
  end

  defp dispatch_update(msg, _state) do
    Logger.debug("telegram_tdlib update: #{inspect(msg)}")
  end
end
