defmodule AlpacaEx.Config do
  @moduledoc """
  Configuration management for AlpacaEx.

  This module handles reading and validating configuration for the Alpaca Markets API,
  including API credentials and endpoint URLs.

  ## Configuration

  Configure AlpacaEx in your application's config files:

      config :alpaca_ex,
        api_key: System.get_env("ALPACA_API_KEY"),
        api_secret: System.get_env("ALPACA_API_SECRET"),
        base_url: "https://paper-api.alpaca.markets",
        ws_url: "wss://stream.data.alpaca.markets/v2/iex"

  ## Environment Variables

  It's recommended to use environment variables for sensitive credentials:

      export ALPACA_API_KEY="your-api-key"
      export ALPACA_API_SECRET="your-api-secret"

  ## URLs

  - Paper Trading REST: `https://paper-api.alpaca.markets`
  - Live Trading REST: `https://api.alpaca.markets`
  - IEx Data Feed WS: `wss://stream.data.alpaca.markets/v2/iex`
  - SIP Data Feed WS: `wss://stream.data.alpaca.markets/v2/sip`
  """

  @default_base_url "https://paper-api.alpaca.markets"
  @default_ws_url "wss://stream.data.alpaca.markets/v2/iex"

  @doc """
  Gets the API key from configuration.

  Raises a `RuntimeError` if the API key is not configured.

  ## Examples

      iex> AlpacaEx.Config.api_key!()
      "PK..."

  """
  @spec api_key!() :: String.t()
  def api_key! do
    case Application.get_env(:alpaca_ex, :api_key) do
      nil ->
        raise """
        AlpacaEx API key not configured!

        Please configure your Alpaca API key in config/config.exs:

            config :alpaca_ex,
              api_key: System.get_env("ALPACA_API_KEY")

        Or set the ALPACA_API_KEY environment variable.
        """

      "" ->
        raise "AlpacaEx API key is configured but empty!"

      key when is_binary(key) ->
        key

      other ->
        raise "AlpacaEx API key must be a string, got: #{inspect(other)}"
    end
  end

  @doc """
  Gets the API secret from configuration.

  Raises a `RuntimeError` if the API secret is not configured.

  ## Examples

      iex> AlpacaEx.Config.api_secret!()
      "SK..."

  """
  @spec api_secret!() :: String.t()
  def api_secret! do
    case Application.get_env(:alpaca_ex, :api_secret) do
      nil ->
        raise """
        AlpacaEx API secret not configured!

        Please configure your Alpaca API secret in config/config.exs:

            config :alpaca_ex,
              api_secret: System.get_env("ALPACA_API_SECRET")

        Or set the ALPACA_API_SECRET environment variable.
        """

      "" ->
        raise "AlpacaEx API secret is configured but empty!"

      secret when is_binary(secret) ->
        secret

      other ->
        raise "AlpacaEx API secret must be a string, got: #{inspect(other)}"
    end
  end

  @doc """
  Gets the base URL for REST API requests.

  Returns the configured base URL or the default paper trading URL.

  ## Examples

      iex> AlpacaEx.Config.base_url()
      "https://paper-api.alpaca.markets"

  """
  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:alpaca_ex, :base_url, @default_base_url)
  end

  @doc """
  Gets the WebSocket URL for streaming data.

  Returns the configured WebSocket URL or the default IEx feed URL.

  ## Examples

      iex> AlpacaEx.Config.ws_url()
      "wss://stream.data.alpaca.markets/v2/iex"

  """
  @spec ws_url() :: String.t()
  def ws_url do
    Application.get_env(:alpaca_ex, :ws_url, @default_ws_url)
  end

  @doc """
  Extracts the data feed type from the WebSocket URL.

  Returns `:iex` for IEx data or `:sip` for SIP data.

  ## Examples

      iex> AlpacaEx.Config.data_feed()
      :iex

  """
  @spec data_feed() :: :iex | :sip
  def data_feed do
    url = ws_url()

    cond do
      String.contains?(url, "/v2/iex") -> :iex
      String.contains?(url, "/v2/sip") -> :sip
      true -> :iex
    end
  end

  @doc """
  Checks if API credentials are configured.

  Returns `true` if both API key and secret are present, `false` otherwise.

  ## Examples

      iex> AlpacaEx.Config.configured?()
      true

  """
  @spec configured?() :: boolean()
  def configured? do
    api_key = Application.get_env(:alpaca_ex, :api_key)
    api_secret = Application.get_env(:alpaca_ex, :api_secret)

    is_binary(api_key) && api_key != "" &&
      is_binary(api_secret) && api_secret != ""
  end

  @doc """
  Checks if the current configuration is for paper trading.

  Returns `true` if using the paper trading URL, `false` otherwise.

  ## Examples

      iex> AlpacaEx.Config.paper_trading?()
      true

  """
  @spec paper_trading?() :: boolean()
  def paper_trading? do
    String.contains?(base_url(), "paper-api.alpaca.markets")
  end

  @doc """
  Validates the current configuration.

  Returns `:ok` if configuration is valid, or `{:error, reasons}` with a list
  of validation errors.

  ## Examples

      iex> AlpacaEx.Config.validate()
      :ok

      iex> AlpacaEx.Config.validate()
      {:error, ["API key not configured", "API secret not configured"]}

  """
  @spec validate() :: :ok | {:error, [String.t()]}
  def validate do
    errors =
      []
      |> validate_api_key()
      |> validate_api_secret()
      |> validate_base_url()
      |> validate_ws_url()

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_api_key(errors) do
    case Application.get_env(:alpaca_ex, :api_key) do
      nil -> ["API key not configured" | errors]
      "" -> ["API key is empty" | errors]
      key when is_binary(key) -> errors
      _ -> ["API key must be a string" | errors]
    end
  end

  defp validate_api_secret(errors) do
    case Application.get_env(:alpaca_ex, :api_secret) do
      nil -> ["API secret not configured" | errors]
      "" -> ["API secret is empty" | errors]
      secret when is_binary(secret) -> errors
      _ -> ["API secret must be a string" | errors]
    end
  end

  defp validate_base_url(errors) do
    case base_url() do
      url when is_binary(url) and url != "" ->
        if String.starts_with?(url, "http") do
          errors
        else
          ["Base URL must start with http:// or https://" | errors]
        end

      _ ->
        ["Base URL must be a non-empty string" | errors]
    end
  end

  defp validate_ws_url(errors) do
    case ws_url() do
      url when is_binary(url) and url != "" ->
        if String.starts_with?(url, "ws") do
          errors
        else
          ["WebSocket URL must start with ws:// or wss://" | errors]
        end

      _ ->
        ["WebSocket URL must be a non-empty string" | errors]
    end
  end
end
