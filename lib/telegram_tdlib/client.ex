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
      process calling `start_link/1`. The handler is monitored and **must
      outlive the client**: when it dies the client stops. Pass an explicit
      long-lived pid when the starting process is short-lived.
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
  def request(server, method, params \\ %{}, timeout \\ @default_timeout)
      when is_map(params) do
    GenServer.call(server, {:request, method, params}, timeout)
  end

  @doc "Fire-and-forget a TDLib `method` with `params`."
  @spec cast(GenServer.server(), String.t(), map()) :: :ok
  def cast(server, method, params \\ %{}) when is_map(params) do
    GenServer.cast(server, {:cast, method, params})
  end

  # ---- Callbacks ----

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # Resolve the handler (pid, registered name, or :via/:global) to a pid so
    # updates and monitoring work uniformly. The client exists to serve its
    # handler; if the handler dies, stop too rather than dropping updates onto a
    # dead process.
    with {:ok, handler} <- resolve_handler(Keyword.fetch!(opts, :handler)) do
      Process.monitor(handler)
      transport = Keyword.get(opts, :transport, TelegramTdlib.Port)

      transport_opts =
        opts
        |> Keyword.drop([:name, :transport, :handler])
        |> Keyword.put(:owner, self())

      case transport.start_link(transport_opts) do
        {:ok, port} ->
          {:ok,
           %{
             transport: transport,
             port: port,
             handler: handler,
             pending: %{},
             seq: 0,
             # Per-instance random prefix so correlation tokens are globally
             # unique (across client instances and restarts), keeping aggregated
             # logs unambiguous rather than every client starting at req-0.
             prefix: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
           }}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve_handler(handler) do
    case GenServer.whereis(handler) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, {:handler_not_found, handler}}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    token = state.prefix <> "-" <> Integer.to_string(state.seq)
    state = %{state | seq: state.seq + 1}

    case safe_send(state, build(method, params, token)) do
      :ok ->
        # Only track the caller once the request was actually accepted, so a
        # send failure fails fast instead of blocking until the call timeout.
        {:noreply, %{state | pending: Map.put(state.pending, token, from)}}

      {:error, _reason} ->
        {:reply, transport_down_error(), state}
    end
  end

  @impl true
  def handle_cast({:cast, method, params}, state) do
    case safe_send(state, build(method, params, nil)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("telegram_tdlib: cast send failed: #{inspect(reason)}")
    end

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

  # Only the transport (above) and the monitored handler (below) drive shutdown.
  # The parent's exit is intercepted by gen_server itself; any other incidental
  # linked process is ignored so it can't take the client down unexpectedly.
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  # The monitored handler died — there is no one left to serve. A graceful
  # handler exit stops the client gracefully; an abnormal one is tagged so it
  # stays distinguishable in crash logs and supervisor decisions.
  def handle_info({:DOWN, _ref, :process, handler, :normal}, %{handler: handler} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, handler, reason}, %{handler: handler} = state) do
    {:stop, {:handler_down, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Drains any callers not already replied to. On the transport-exit path
    # `pending` was cleared before stopping, so this is a no-op there.
    reply_all_pending(state.pending, transport_down_error())
    :ok
  end

  # ---- helpers ----

  # Sends via the transport, isolating Client from transport failures: a
  # dead-transport exit (or any raise from a misbehaving transport) becomes a
  # send error. The linked-process {:EXIT, ...} that follows drains `pending`.
  defp safe_send(state, request) do
    state.transport.send(state.port, request)
  rescue
    e -> {:error, {:send_error, e}}
  catch
    :exit, _ -> {:error, :transport_down}
  end

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

  # Synthetic error mirroring TDLib's error object shape (code + message) so
  # callers can pattern-match transport failures the same way as TDLib errors.
  defp transport_down_error,
    do: {:error, %{"@type" => "error", "code" => 0, "message" => "transport_down"}}

  defp dispatch_update(msg, %{handler: handler}) do
    # handler is always a resolved pid (see resolve_handler/1).
    Kernel.send(handler, {:tdlib_update, msg})
  end
end
