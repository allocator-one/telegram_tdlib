defmodule TelegramTdlib.Transport do
  @moduledoc """
  The contract `TelegramTdlib.Client` requires of a transport.

  A transport is a process that carries TDLib request maps to an underlying
  client and delivers each TDLib response/update back to its `:owner` as a
  `{:tdlib, map}` message. `TelegramTdlib.Port` is the production implementation
  (a BEAM `Port` over the C shim); the test suite supplies an in-memory fake.

  It must be started **linked** to the caller (so `Client`, which traps exits,
  observes its termination and drains in-flight requests).
  """

  @doc """
  Start the transport, linked to the caller. Options include `:owner` — the pid
  that should receive `{:tdlib, map}` messages.
  """
  @callback start_link(keyword()) :: GenServer.on_start()

  @doc """
  Hand a TDLib request (a plain map) to the transport. Returns `:ok`, or
  `{:error, reason}` if the request could not be handed off (e.g. encode failure
  or a closed channel).
  """
  @callback send(GenServer.server(), map()) :: :ok | {:error, term()}
end
