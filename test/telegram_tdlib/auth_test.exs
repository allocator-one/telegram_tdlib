defmodule TelegramTdlib.AuthTest do
  use ExUnit.Case, async: true

  alias TelegramTdlib.Auth

  @config %{api_id: 12_345, api_hash: "deadbeef"}

  describe "next_action/2" do
    test "waitTdlibParameters yields setTdlibParameters carrying the api credentials" do
      assert {:request, req} =
               Auth.next_action(%{"@type" => "authorizationStateWaitTdlibParameters"}, @config)

      assert req["@type"] == "setTdlibParameters"
      assert req["api_id"] == 12_345
      assert req["api_hash"] == "deadbeef"
      assert req["use_test_dc"] == false
    end

    test "database_directory is configurable and defaults to tdlib-db" do
      assert {:request, %{"database_directory" => "tdlib-db"}} =
               Auth.next_action(%{"@type" => "authorizationStateWaitTdlibParameters"}, @config)

      config = Map.put(@config, :database_directory, "/var/lib/tg")

      assert {:request, %{"database_directory" => "/var/lib/tg"}} =
               Auth.next_action(%{"@type" => "authorizationStateWaitTdlibParameters"}, config)
    end

    test "interactive states report which input they need" do
      assert {:need, :phone_number} =
               Auth.next_action(%{"@type" => "authorizationStateWaitPhoneNumber"}, @config)

      assert {:need, :code} =
               Auth.next_action(%{"@type" => "authorizationStateWaitCode"}, @config)

      assert {:need, :password} =
               Auth.next_action(%{"@type" => "authorizationStateWaitPassword"}, @config)
    end

    test "ready state signals completion" do
      assert :ready = Auth.next_action(%{"@type" => "authorizationStateReady"}, @config)
    end

    test "states this helper does not act on are reported as unhandled" do
      assert {:unhandled, "authorizationStateClosing"} =
               Auth.next_action(%{"@type" => "authorizationStateClosing"}, @config)
    end
  end

  describe "request builders" do
    test "phone_request/1" do
      assert Auth.phone_request("+15551234567") == %{
               "@type" => "setAuthenticationPhoneNumber",
               "phone_number" => "+15551234567"
             }
    end

    test "code_request/1" do
      assert Auth.code_request("12345") == %{
               "@type" => "checkAuthenticationCode",
               "code" => "12345"
             }
    end

    test "password_request/1" do
      assert Auth.password_request("hunter2") == %{
               "@type" => "checkAuthenticationPassword",
               "password" => "hunter2"
             }
    end
  end
end
