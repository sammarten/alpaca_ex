defmodule AlpacaEx do
  @moduledoc """
  AlpacaEx is an Elixir client for the Alpaca Markets API.

  This library provides both REST API and WebSocket streaming capabilities
  for interacting with Alpaca Markets, a commission-free trading platform.

  ## Features

  - **REST API Client** - Complete access to Alpaca's REST API for market data, account management, and order execution
  - **WebSocket Streaming** - Real-time market data streaming (quotes, bars, trades)
  - **Type Safety** - Uses Decimal for precise price handling and DateTime for timestamps
  - **Automatic Pagination** - Handles large data requests automatically
  - **Rate Limiting** - Built-in retry logic for rate-limited requests
  - **Reconnection** - Automatic WebSocket reconnection with exponential backoff

  ## Configuration

  Add AlpacaEx to your application's configuration:

      config :alpaca_ex,
        api_key: System.get_env("ALPACA_API_KEY"),
        api_secret: System.get_env("ALPACA_API_SECRET"),
        base_url: "https://paper-api.alpaca.markets",
        ws_url: "wss://stream.data.alpaca.markets/v2/iex"

  ## Usage

  ### REST API

      # Get account information
      {:ok, account} = AlpacaEx.Client.get_account()

      # Get historical bars
      {:ok, bars} = AlpacaEx.Client.get_bars("AAPL",
        timeframe: "1Min",
        start: ~U[2024-01-01 09:30:00Z],
        end: ~U[2024-01-01 16:00:00Z]
      )

      # Place an order
      {:ok, order} = AlpacaEx.Client.place_order(%{
        symbol: "AAPL",
        qty: 10,
        side: "buy",
        type: "market",
        time_in_force: "day"
      })

  ### WebSocket Streaming

      # Define a callback module
      defmodule MyHandler do
        def handle_message(%{type: :bar, symbol: symbol, close: close}, state) do
          IO.puts("Bar for \#{symbol}: $\#{close}")
          {:ok, state}
        end

        def handle_message(%{type: :quote, symbol: symbol, ask_price: ask}, state) do
          IO.puts("Quote for \#{symbol}: $\#{ask}")
          {:ok, state}
        end

        def handle_message(_message, state) do
          {:ok, state}
        end
      end

      # Start streaming
      {:ok, pid} = AlpacaEx.Stream.start_link(
        callback_module: MyHandler,
        callback_state: %{}
      )

      # Subscribe to real-time data
      AlpacaEx.Stream.subscribe(pid, %{
        bars: ["AAPL", "TSLA"],
        quotes: ["AAPL", "TSLA"]
      })
  """

  @doc """
  Returns the version of the AlpacaEx library.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:alpaca_ex, :vsn) |> to_string()
  end
end
