defmodule TelegramTdlib do
  @moduledoc """
  Elixir bindings for Telegram's [TDLib](https://core.telegram.org/tdlib).

  TDLib is hosted out-of-process: a small C++ shim wraps Telegram's official
  `td_json_client` interface and is driven over a BEAM `Port`, so a crash or
  hang inside TDLib is isolated from the VM and recoverable by a supervisor.

  ## Layers

    * `TelegramTdlib.Client` — a `GenServer` owning one TDLib client. Send
      methods with `request/3` (awaits the correlated response) or `cast/3`
      (fire-and-forget). Unsolicited updates are delivered to a handler pid.
    * `TelegramTdlib.Port` — owns the external shim process and frames JSON to
      and from it.
    * `TelegramTdlib.Auth` — pure helpers for TDLib's login state machine.

  Requests and responses are plain maps with string keys, mirroring TDLib's
  JSON schema (the `@type` field selects the method/object). Typed wrappers can
  be layered on top later.

  ## Status

  Early walking skeleton: transport + auth flow. Not yet a complete API.
  """

  alias TelegramTdlib.Client

  @doc "Start a TDLib client. See `TelegramTdlib.Client.start_link/1`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Client.start_link(opts)

  @doc "Send a TDLib method and await its response."
  @spec request(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def request(client, method, params \\ %{}), do: Client.request(client, method, params)

  @doc "Fire-and-forget a TDLib method."
  @spec cast(GenServer.server(), String.t(), map()) :: :ok
  def cast(client, method, params \\ %{}), do: Client.cast(client, method, params)
end
