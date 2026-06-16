# telegram_tdlib

Elixir bindings for Telegram's [TDLib](https://core.telegram.org/tdlib) (the
official Telegram Database Library), exposing a **full Telegram client** — not a
bot — to Elixir applications.

> **Status: early walking skeleton.** Transport (port + framing) and the login
> state machine are in place. The typed API surface is intentionally minimal;
> requests and responses are plain maps mirroring TDLib's JSON schema.

## Why a port, not a NIF

TDLib is a large C++ library with its own thread pool, cryptography, and network
I/O. Loading it into the BEAM as a NIF means a crash or hang inside TDLib takes
down the **entire VM** — no supervisor can recover it.

Instead, `telegram_tdlib` runs TDLib in a separate OS process: a small C++ shim
wraps Telegram's official `td_json_client` interface and is driven over a BEAM
[`Port`](https://www.erlang.org/doc/man/erlang#open_port-2). A TDLib crash is
then just a port exit that a supervisor restarts. Telegram designed
`td_json_client` precisely for out-of-process language bindings, so this is the
sanctioned integration path.

```
  ┌────────────┐   {:packet,4} JSON   ┌──────────────────────┐   td_json_client   ┌────────┐
  │  Elixir    │ ◀──────────────────▶ │  telegram_tdlib_shim │ ◀────────────────▶ │ TDLib  │
  │  Client    │      stdin/stdout    │       (C++ port)     │   td_send/receive  │ (libtdjson)
  └────────────┘                      └──────────────────────┘                    └────────┘
```

## Requirements

* Elixir `~> 1.16`, OTP 26+
* A C++14 compiler
* **TDLib (`libtdjson`)** installed and discoverable at compile time:
  * macOS: `brew install tdlib`
  * Linux: build from source (<https://github.com/tdlib/td>) and set
    `TDLIB_DIR` to its install prefix, or install a system package that
    provides `libtdjson`.

If `libtdjson` is not found, the native build is **skipped** (not failed) so the
pure-Elixir code and tests still compile. In that state `TelegramTdlib.start_link/1`
fails fast with a clear `{:error, reason}` (the shim is missing) rather than
starting a half-working client.

## Installation

```elixir
def deps do
  [{:telegram_tdlib, "~> 0.1"}]
end
```

The native shim is located via `TDLIB_DIR`, falling back to `brew --prefix
tdlib`. Override when needed:

```sh
TDLIB_DIR=/opt/td mix compile
```

## Getting Telegram API credentials

You need an `api_id` and `api_hash` from <https://my.telegram.org/apps>
(register an application — takes a couple of minutes). These identify your
application to Telegram and are required by `setTdlibParameters`.

## Usage

```elixir
# Start a client; updates go to the calling process by default. Pass a
# long-lived `handler:` pid when the starting process is short-lived.
{:ok, client} = TelegramTdlib.start_link(handler: self())

# Synchronous, no network — proves the bridge works. getAuthorizationState is
# answered locally and echoes the correlation token.
{:ok, %{"@type" => "authorizationState" <> _}} =
  TelegramTdlib.request(client, "getAuthorizationState")

# Source credentials from config/env — never hardcode them.
config = %{
  api_id: String.to_integer(System.fetch_env!("TELEGRAM_API_ID")),
  api_hash: System.fetch_env!("TELEGRAM_API_HASH")
}

# TDLib announces auth steps via updates; respond with TelegramTdlib.Auth:
receive do
  {:tdlib_update, %{"@type" => "updateAuthorizationState", "authorization_state" => st}} ->
    case TelegramTdlib.Auth.next_action(st, config) do
      {:request, req} -> TelegramTdlib.cast(client, req["@type"], Map.delete(req, "@type"))
      {:need, :phone_number} -> # prompt the user, then send Auth.phone_request/1
      :ready -> IO.puts("logged in")
      _ -> :ok
    end
end
```

## ⚠️ Terms of Service

Logging in as a user (a "userbot") rather than a bot is **against Telegram's
Terms of Service** and can result in your account being **limited or banned**.
Use a dedicated number you can afford to lose, understand the risk, and prefer
the official [Bot API](https://core.telegram.org/bots/api) where it suffices.

## License

MIT — see [LICENSE](LICENSE). TDLib itself is distributed under the Boost
Software License 1.0.
