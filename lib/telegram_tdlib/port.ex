defmodule TelegramTdlib.Port do
  @moduledoc """
  Owns the external `td_json_client` shim as a BEAM `Port` and bridges JSON
  messages to and from it.

  Outgoing requests are plain maps, JSON-encoded and sent with `send/2`. Each
  TDLib response or update is decoded and delivered to the configured `:owner`
  as a `{:tdlib, map}` message.

  Framing uses the port's `{:packet, 4}` option: a 4-byte big-endian length
  prefix on every message in both directions, matching the C shim.

  The process is linked to its owner; if the shim exits the server stops with
  `{:shim_exited, status}`, which (via the link) the owner observes.
  """
  use GenServer
  @behaviour TelegramTdlib.Transport
  require Logger

  @shim "telegram_tdlib_shim"

  # ---- API ----

  @doc """
  Start the port.

  Options:

    * `:owner` (required) — pid that receives `{:tdlib, map}` messages.
    * `:name` — optional GenServer name.
  """
  @impl TelegramTdlib.Transport
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Send a TDLib request (a plain map) to the underlying client.

  Synchronous so the caller learns whether the request was handed to the port:
  returns `:ok`, or `{:error, reason}` if the request could not be encoded or the
  port is already closed.
  """
  @impl TelegramTdlib.Transport
  @spec send(GenServer.server(), map()) :: :ok | {:error, term()}
  def send(server, %{} = request) do
    GenServer.call(server, {:send, request})
  end

  # ---- Callbacks ----

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    case shim_path() do
      {:ok, path} ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :use_stdio,
            :exit_status,
            {:packet, 4}
          ])

        {:ok, %{port: port, owner: owner}}

      {:error, reason} ->
        Logger.error("""
        telegram_tdlib: cannot start the TDLib shim (#{inspect(reason)}).

        The native build is skipped when libtdjson is not found at compile time.
        Install TDLib (e.g. `brew install tdlib`, or build from
        https://github.com/tdlib/td) and recompile this dependency.
        """)

        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, request}, _from, state) do
    {:reply, do_send(request, state.port), state}
  end

  defp do_send(request, port) do
    case Jason.encode(request) do
      {:ok, payload} ->
        try do
          if Port.command(port, payload), do: :ok, else: {:error, :port_closed}
        rescue
          ArgumentError -> {:error, :port_closed}
        end

      {:error, reason} ->
        {:error, {:encode_error, reason}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, %{} = msg} ->
        Kernel.send(state.owner, {:tdlib, msg})

      {:ok, other} ->
        Logger.error("telegram_tdlib: ignoring non-object TDLib payload: #{inspect(other)}")

      {:error, reason} ->
        Logger.error("telegram_tdlib: could not decode TDLib message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:shim_exited, status}, state}
  end

  # ---- helpers ----

  defp shim_path do
    case :code.priv_dir(:telegram_tdlib) do
      {:error, _} ->
        {:error, :telegram_tdlib_app_not_loaded}

      priv ->
        path = Path.join(priv, @shim)

        if File.exists?(path),
          do: {:ok, String.to_charlist(path)},
          else: {:error, {:shim_missing, path}}
    end
  end
end
