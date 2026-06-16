defmodule TelegramTdlib.IntegrationTest do
  @moduledoc """
  Exercises the full stack — `Client` → `Port` → the C++ shim → TDLib and back —
  with no network. Requires TDLib (libtdjson) installed and the native shim
  built, so it is excluded by default. Run with `mix test --include integration`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  test "round-trips a correlated response through the real port and shim" do
    {:ok, client} = TelegramTdlib.start_link(handler: self())

    # getAuthorizationState is answered locally (no network) and echoes @extra,
    # proving framing, JSON, and correlation across the language boundary.
    assert {:ok, %{"@type" => "authorizationState" <> _}} =
             TelegramTdlib.request(client, "getAuthorizationState")
  end
end
