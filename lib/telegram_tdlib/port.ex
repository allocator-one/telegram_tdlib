defmodule TelegramTdlib.Port do
  @moduledoc """
  Owns the external `td_json_client` shim as a BEAM `Port` and bridges JSON
  messages to and from it.

  Outgoing requests are plain maps, JSON-encoded and sent with `send/2`. Each
  TDLib response or update is decoded and delivered to the configured `:owner`
  as a `{:tdlib, map}` message.

  Framing uses the port's `{:packet, 4}` option: a 4-byte big-endian length
  prefix on every message in both directions, matching the C shim.
  """
  use GenServer
  require Logger

  @shim "telegram_tdlib_shim"

  # ---- API ----

  @doc """
  Start the port.

  Options:

    * `:owner` (required) — pid that receives `{:tdlib, map}` messages.
    * `:name` — optional GenServer name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Send a TDLib request (a plain map) to the underlying client."
  @spec send(GenServer.server(), map()) :: :ok
  def send(server, %{} = request) do
    GenServer.cast(server, {:send, request})
  end

  # ---- Callbacks ----

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    Process.flag(:trap_exit, true)

    port =
      Port.open({:spawn_executable, shim_path()}, [
        :binary,
        :exit_status,
        {:packet, 4}
      ])

    {:ok, %{port: port, owner: owner}}
  end

  @impl true
  def handle_cast({:send, request}, state) do
    Port.command(state.port, Jason.encode!(request))
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, msg} ->
        Kernel.send(state.owner, {:tdlib, msg})

      {:error, reason} ->
        Logger.error("telegram_tdlib: could not decode TDLib message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:shim_exited, status}, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:shim_down, reason}, state}
  end

  # ---- helpers ----

  defp shim_path do
    path = Path.join(:code.priv_dir(:telegram_tdlib), @shim)

    unless File.exists?(path) do
      raise """
      telegram_tdlib shim not found at #{path}.

      The native build was skipped because TDLib (libtdjson) was not found at
      compile time. Install TDLib (e.g. `brew install tdlib`, or build from
      https://github.com/tdlib/td) and recompile this dependency.
      """
    end

    String.to_charlist(path)
  end
end
