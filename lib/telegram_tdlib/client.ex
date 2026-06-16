defmodule TelegramTdlib.Client do
  @moduledoc """
  A `GenServer` owning a single TDLib client (via `TelegramTdlib.Port`).

  Provides:

    * `request/4` — send a TDLib method and await its correlated response.
      Correlation uses TDLib's `@extra` field: a token is injected into the
      request and matched against the `@extra` echoed on the response.
    * `cast/3` — fire-and-forget a TDLib method.
    * update delivery — every unsolicited TDLib update (no matching pending
      request) is sent to the configured `:handler` pid as `{:tdlib_update, map}`,
      or logged at debug level when no handler is set.

  This is a thin, schema-agnostic layer: methods are TDLib `@type` strings and
  params/responses are plain maps with string keys.
  """
  use GenServer
  require Logger

  alias TelegramTdlib.Port

  @default_timeout 10_000

  # ---- API ----

  @doc """
  Start the client.

  Options:

    * `:handler` — pid to receive `{:tdlib_update, map}` updates (defaults to
      the starting process).
    * `:name` — optional GenServer name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Send a TDLib `method` (its `@type`) with `params` and await the response.

  Returns `{:ok, response_map}`, or `{:error, error_map}` when TDLib replies
  with an `error` object.
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
    handler = Keyword.get(opts, :handler, self())
    {:ok, port} = Port.start_link(owner: self())

    {:ok, %{port: port, handler: handler, pending: %{}, seq: 0}}
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    token = "req-" <> Integer.to_string(state.seq)
    Port.send(state.port, build(method, params, token))

    {:noreply, %{state | seq: state.seq + 1, pending: Map.put(state.pending, token, from)}}
  end

  @impl true
  def handle_cast({:cast, method, params}, state) do
    Port.send(state.port, build(method, params, nil))
    {:noreply, state}
  end

  @impl true
  def handle_info({:tdlib, %{"@extra" => token} = msg}, state) do
    case Map.pop(state.pending, token) do
      {nil, _pending} ->
        dispatch_update(msg, state)
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, classify(msg))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:tdlib, msg}, state) do
    dispatch_update(msg, state)
    {:noreply, state}
  end

  # ---- helpers ----

  defp build(method, params, token) do
    base = params |> Map.new() |> Map.put("@type", method)
    if token, do: Map.put(base, "@extra", token), else: base
  end

  defp classify(%{"@type" => "error"} = err), do: {:error, err}
  defp classify(msg), do: {:ok, msg}

  defp dispatch_update(msg, %{handler: handler}) when is_pid(handler) do
    Kernel.send(handler, {:tdlib_update, msg})
  end

  defp dispatch_update(msg, _state) do
    Logger.debug("telegram_tdlib update: #{inspect(msg)}")
  end
end
