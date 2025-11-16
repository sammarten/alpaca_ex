defmodule AlpacaEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/yourusername/alpaca_ex"

  def project do
    [
      app: :alpaca_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "AlpacaEx",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:websockex, "~> 0.4.3"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.1"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir client for Alpaca Markets API - REST and WebSocket streaming"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
