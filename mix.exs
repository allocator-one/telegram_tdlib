defmodule TelegramTdlib.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mstroeck/telegram_tdlib"

  def project do
    [
      app: :telegram_tdlib,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      name: "telegram_tdlib",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir bindings for Telegram's TDLib (td_json_client), hosted as a " <>
      "supervised external port so TDLib crashes never take down the VM."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "TDLib" => "https://core.telegram.org/tdlib"},
      files: ~w(lib c_src Makefile mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
