defmodule TelegramTdlib.Auth do
  @moduledoc """
  Pure helpers for TDLib's login state machine.

  TDLib drives authentication by emitting `updateAuthorizationState` updates;
  the client responds to each state. The happy path for a **user** (not bot)
  login is:

      authorizationStateWaitTdlibParameters  -> setTdlibParameters
      authorizationStateWaitPhoneNumber      -> setAuthenticationPhoneNumber
      authorizationStateWaitCode             -> checkAuthenticationCode
      authorizationStateWaitPassword         -> checkAuthenticationPassword  (2FA)
      authorizationStateReady                -> logged in

  This module is side-effect free: `next_action/2` maps an authorization state
  (plus config) to the request that should be sent next, or signals that
  interactive input is required. The caller decides how to source the phone
  number, login code, and 2FA password.
  """

  @type config :: %{
          required(:api_id) => integer(),
          required(:api_hash) => String.t(),
          optional(:database_directory) => String.t(),
          optional(:use_test_dc) => boolean()
        }

  @type action ::
          {:request, map()}
          | {:need, :phone_number | :code | :password}
          | :ready
          | {:unhandled, String.t()}

  @doc """
  Map an `authorizationState` map (TDLib `@type`) plus `config` to the next step.

    * `{:request, map}` — send this TDLib request next.
    * `{:need, field}` — interactive input required (`:phone_number`, `:code`,
      or `:password`); use `phone_request/1`, `code_request/1`, or
      `password_request/1` to build the follow-up.
    * `:ready` — authorization complete.
    * `{:unhandled, type}` — a state this helper does not act on (e.g.
      `authorizationStateClosing`).
  """
  @spec next_action(map(), config()) :: action()
  def next_action(%{"@type" => "authorizationStateWaitTdlibParameters"}, config) do
    {:request,
     %{
       "@type" => "setTdlibParameters",
       "api_id" => Map.fetch!(config, :api_id),
       "api_hash" => Map.fetch!(config, :api_hash),
       "database_directory" => Map.get(config, :database_directory, "tdlib-db"),
       "use_test_dc" => Map.get(config, :use_test_dc, false),
       "system_language_code" => "en",
       "device_model" => "telegram_tdlib",
       "application_version" => "0.1.0"
     }}
  end

  def next_action(%{"@type" => "authorizationStateWaitPhoneNumber"}, _config),
    do: {:need, :phone_number}

  def next_action(%{"@type" => "authorizationStateWaitCode"}, _config),
    do: {:need, :code}

  def next_action(%{"@type" => "authorizationStateWaitPassword"}, _config),
    do: {:need, :password}

  def next_action(%{"@type" => "authorizationStateReady"}, _config),
    do: :ready

  def next_action(%{"@type" => other}, _config),
    do: {:unhandled, other}

  @doc "Build the request submitting a phone number."
  @spec phone_request(String.t()) :: map()
  def phone_request(phone),
    do: %{"@type" => "setAuthenticationPhoneNumber", "phone_number" => phone}

  @doc "Build the request submitting a login code."
  @spec code_request(String.t()) :: map()
  def code_request(code),
    do: %{"@type" => "checkAuthenticationCode", "code" => code}

  @doc "Build the request submitting a 2FA password."
  @spec password_request(String.t()) :: map()
  def password_request(password),
    do: %{"@type" => "checkAuthenticationPassword", "password" => password}
end
