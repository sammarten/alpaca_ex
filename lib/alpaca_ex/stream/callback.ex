defmodule AlpacaEx.Stream.Callback do
  @moduledoc """
  Behaviour for modules that handle AlpacaEx.Stream messages.

  Implement this behaviour to receive and process real-time market data
  from the Alpaca WebSocket stream.

  ## Example

      defmodule MyApp.StreamHandler do
        @behaviour AlpacaEx.Stream.Callback

        @impl true
        def handle_message(%{type: :quote, symbol: symbol} = quote, state) do
          # Process quote...
          {:ok, state}
        end

        @impl true
        def handle_message(%{type: :bar, symbol: symbol} = bar, state) do
          # Process bar...
          {:ok, state}
        end

        @impl true
        def handle_message(_message, state) do
          # Handle unknown messages
          {:ok, state}
        end
      end

  ## Message Types

  The callback will receive normalized messages with the following structures:

  ### Quote
  ```elixir
  %{
    type: :quote,
    symbol: "AAPL",
    bid_price: #Decimal<185.50>,
    bid_size: 100,
    ask_price: #Decimal<185.52>,
    ask_size: 100,
    timestamp: ~U[2024-01-01 09:30:00.000000Z],
    bid_exchange: "V",
    ask_exchange: "V",
    conditions: ["R"]
  }
  ```

  ### Bar
  ```elixir
  %{
    type: :bar,
    symbol: "AAPL",
    open: #Decimal<185.20>,
    high: #Decimal<185.60>,
    low: #Decimal<185.15>,
    close: #Decimal<185.50>,
    volume: 12500,
    timestamp: ~U[2024-01-01 09:30:00.000000Z],
    vwap: #Decimal<185.35>,
    trade_count: 150
  }
  ```

  ### Trade
  ```elixir
  %{
    type: :trade,
    symbol: "AAPL",
    price: #Decimal<185.50>,
    size: 100,
    timestamp: ~U[2024-01-01 09:30:00.000000Z],
    exchange: "V",
    conditions: ["@"],
    id: "123456789"
  }
  ```

  ### Status
  ```elixir
  %{
    type: :status,
    symbol: "AAPL",
    status_code: "H",
    status_message: "Halted",
    reason_code: "LUDP",
    reason_message: "Volatility Trading Pause",
    timestamp: ~U[2024-01-01 09:30:00.000000Z]
  }
  ```

  ### Connection
  ```elixir
  %{
    type: :connection,
    status: :connected | :disconnected | :authenticated | :subscribed,
    ...
  }
  ```
  """

  @doc """
  Handles an incoming message from the Alpaca stream.

  This callback is invoked for each message received from the WebSocket.
  The implementation should process the message and return the updated state.

  ## Parameters

  - `message` - A map containing the normalized message data (see module docs for structure)
  - `state` - The current callback state

  ## Returns

  - `{:ok, new_state}` - The callback succeeded and returns the updated state

  ## Example

      @impl true
      def handle_message(%{type: :quote, symbol: symbol, bid_price: bid}, state) do
        Logger.info("Quote for \#{symbol}: $\#{bid}")
        {:ok, state}
      end
  """
  @callback handle_message(message :: map(), state :: any()) :: {:ok, new_state :: any()}
end
