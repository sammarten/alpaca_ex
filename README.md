# AlpacaEx

[![Hex.pm](https://img.shields.io/hexpm/v/alpaca_ex.svg)](https://hex.pm/packages/alpaca_ex)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/alpaca_ex)

Elixir client for the [Alpaca Markets API](https://alpaca.markets/) - providing both REST API and WebSocket streaming capabilities for commission-free stock trading.

## Features

- **REST API Client** - Complete access to Alpaca's REST API
  - Market data (bars, quotes, trades)
  - Account management
  - Order execution and management
  - Position tracking
- **WebSocket Streaming** - Real-time market data
  - Live quotes
  - Minute bars
  - Trade updates
  - Market status
- **Type Safety** - Uses `Decimal` for precise price handling and `DateTime` for timestamps
- **Automatic Pagination** - Handles large data requests seamlessly
- **Rate Limiting** - Built-in retry logic with exponential backoff
- **Auto-Reconnection** - WebSocket reconnects automatically with exponential backoff
- **Paper & Live Trading** - Support for both paper and live trading environments

## Installation

Add `alpaca_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:alpaca_ex, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Configuration

Configure AlpacaEx in your `config/config.exs`:

```elixir
config :alpaca_ex,
  api_key: System.get_env("ALPACA_API_KEY"),
  api_secret: System.get_env("ALPACA_API_SECRET"),
  base_url: "https://paper-api.alpaca.markets",
  ws_url: "wss://stream.data.alpaca.markets/v2/iex"
```

### Environment Variables

It's recommended to use environment variables for your credentials:

```bash
export ALPACA_API_KEY="your-api-key"
export ALPACA_API_SECRET="your-api-secret"
```

### URLs

**REST API:**
- Paper Trading: `https://paper-api.alpaca.markets`
- Live Trading: `https://api.alpaca.markets`

**WebSocket:**
- IEx Data Feed: `wss://stream.data.alpaca.markets/v2/iex` (Free)
- SIP Data Feed: `wss://stream.data.alpaca.markets/v2/sip` (Requires subscription)

## Getting Started

### Get API Credentials

1. Sign up for a free account at [Alpaca Markets](https://alpaca.markets/)
2. Generate API keys from the dashboard
3. Start with paper trading to test your strategies

### Basic Usage

```elixir
# Check your account
{:ok, account} = AlpacaEx.Client.get_account()
IO.inspect(account.buying_power)

# Get the latest price
{:ok, bar} = AlpacaEx.Client.get_latest_bar("AAPL")
IO.inspect(bar.close)

# Place a market order
{:ok, order} = AlpacaEx.Client.place_order(%{
  symbol: "AAPL",
  qty: 10,
  side: "buy",
  type: "market",
  time_in_force: "day"
})
```

## REST API Examples

### Market Data

#### Get Historical Bars

```elixir
# Get 1-minute bars for a single symbol
{:ok, bars} = AlpacaEx.Client.get_bars("AAPL",
  timeframe: "1Min",
  start: ~U[2024-01-01 09:30:00Z],
  end: ~U[2024-01-01 16:00:00Z]
)

# Get hourly bars for multiple symbols
{:ok, multi_bars} = AlpacaEx.Client.get_bars(["AAPL", "TSLA", "GOOGL"],
  timeframe: "1Hour",
  start: ~U[2024-01-01 00:00:00Z],
  end: ~U[2024-01-31 23:59:59Z]
)

# Access bars by symbol
aapl_bars = multi_bars["AAPL"]
Enum.each(aapl_bars, fn bar ->
  IO.puts("#{bar.timestamp}: $#{bar.close}")
end)
```

#### Get Latest Market Data

```elixir
# Latest bar (OHLCV)
{:ok, bar} = AlpacaEx.Client.get_latest_bar("AAPL")
IO.puts("Close: $#{bar.close}, Volume: #{bar.volume}")

# Latest quote (bid/ask)
{:ok, quote} = AlpacaEx.Client.get_latest_quote("AAPL")
IO.puts("Bid: $#{quote.bid_price} x #{quote.bid_size}")
IO.puts("Ask: $#{quote.ask_price} x #{quote.ask_size}")

# Latest trade
{:ok, trade} = AlpacaEx.Client.get_latest_trade("AAPL")
IO.puts("Last: $#{trade.price} (#{trade.size} shares)")
```

### Account & Positions

```elixir
# Get account information
{:ok, account} = AlpacaEx.Client.get_account()
IO.puts("Buying Power: $#{account.buying_power}")
IO.puts("Portfolio Value: $#{account.portfolio_value}")
IO.puts("Cash: $#{account.cash}")

# Get all positions
{:ok, positions} = AlpacaEx.Client.get_positions()
Enum.each(positions, fn pos ->
  IO.puts("#{pos.symbol}: #{pos.qty} shares @ $#{pos.current_price}")
  IO.puts("  P&L: $#{pos.unrealized_pl} (#{pos.unrealized_plpc}%)")
end)

# Get specific position
{:ok, position} = AlpacaEx.Client.get_position("AAPL")
```

### Orders

#### Place Orders

```elixir
# Market order
{:ok, order} = AlpacaEx.Client.place_order(%{
  symbol: "AAPL",
  qty: 10,
  side: "buy",
  type: "market",
  time_in_force: "day"
})

# Limit order
{:ok, order} = AlpacaEx.Client.place_order(%{
  symbol: "AAPL",
  qty: 10,
  side: "buy",
  type: "limit",
  time_in_force: "gtc",
  limit_price: Decimal.new("150.00")
})

# Stop-loss order
{:ok, order} = AlpacaEx.Client.place_order(%{
  symbol: "AAPL",
  qty: 10,
  side: "sell",
  type: "stop",
  time_in_force: "gtc",
  stop_price: Decimal.new("145.00")
})

# Bracket order (with take-profit and stop-loss)
{:ok, order} = AlpacaEx.Client.place_order(%{
  symbol: "AAPL",
  qty: 100,
  side: "buy",
  type: "market",
  time_in_force: "gtc",
  order_class: "bracket",
  take_profit: %{limit_price: Decimal.new("155.00")},
  stop_loss: %{stop_price: Decimal.new("145.00")}
})
```

#### Manage Orders

```elixir
# List open orders
{:ok, orders} = AlpacaEx.Client.list_orders(status: "open")

# List all orders (last 100)
{:ok, all_orders} = AlpacaEx.Client.list_orders(status: "all", limit: 100)

# Get specific order
{:ok, order} = AlpacaEx.Client.get_order("order-id-here")

# Cancel an order
{:ok, _} = AlpacaEx.Client.cancel_order("order-id-here")

# Cancel all open orders
{:ok, cancelled} = AlpacaEx.Client.cancel_all_orders()
```

## WebSocket Streaming

### Setup Callback Module

Create a module to handle incoming market data:

```elixir
defmodule MyApp.MarketDataHandler do
  require Logger

  def handle_message(%{type: :bar, symbol: symbol, close: close} = bar, state) do
    Logger.info("Bar: #{symbol} closed at $#{close}")
    # Your custom logic here
    # Maybe update a GenServer, write to database, etc.
    {:ok, state}
  end

  def handle_message(%{type: :quote, symbol: symbol} = quote, state) do
    Logger.info("Quote: #{symbol} - Bid: $#{quote.bid_price}, Ask: $#{quote.ask_price}")
    {:ok, state}
  end

  def handle_message(%{type: :trade, symbol: symbol, price: price, size: size}, state) do
    Logger.info("Trade: #{symbol} - #{size} shares @ $#{price}")
    {:ok, state}
  end

  def handle_message(%{type: :status} = status, state) do
    Logger.info("Status: #{status.symbol} - #{status.status_message}")
    {:ok, state}
  end

  def handle_message(%{type: :connection, status: :subscribed}, state) do
    Logger.info("Successfully subscribed to market data")
    {:ok, state}
  end

  def handle_message(%{type: :connection, status: :disconnected}, state) do
    Logger.warning("Disconnected from market data stream")
    {:ok, state}
  end

  def handle_message(_message, state) do
    {:ok, state}
  end
end
```

### Start Streaming

```elixir
# Start the stream in your application supervision tree
children = [
  {AlpacaEx.Stream,
    callback_module: MyApp.MarketDataHandler,
    callback_state: %{},
    name: MyApp.MarketStream
  }
]

Supervisor.start_link(children, strategy: :one_for_one)

# Subscribe to data
AlpacaEx.Stream.subscribe(MyApp.MarketStream, %{
  bars: ["AAPL", "TSLA", "GOOGL"],
  quotes: ["AAPL"],
  trades: ["TSLA"]
})

# Check status
AlpacaEx.Stream.status(MyApp.MarketStream)
#=> :subscribed

# Check subscriptions
AlpacaEx.Stream.subscriptions(MyApp.MarketStream)
#=> %{bars: ["AAPL", "TSLA", "GOOGL"], quotes: ["AAPL"], trades: ["TSLA"], statuses: []}

# Unsubscribe from specific data
AlpacaEx.Stream.unsubscribe(MyApp.MarketStream, %{
  bars: ["GOOGL"]
})
```

### Message Types

The callback receives normalized messages with the following structure:

#### Bar (Minute Candle)
```elixir
%{
  type: :bar,
  symbol: "AAPL",
  open: #Decimal<185.20>,
  high: #Decimal<185.60>,
  low: #Decimal<184.90>,
  close: #Decimal<185.45>,
  volume: 2_300_000,
  timestamp: ~U[2024-01-15 14:30:00Z],
  vwap: #Decimal<185.32>,
  trade_count: 150
}
```

#### Quote (Best Bid/Ask)
```elixir
%{
  type: :quote,
  symbol: "AAPL",
  bid_price: #Decimal<185.50>,
  bid_size: 100,
  ask_price: #Decimal<185.52>,
  ask_size: 200,
  timestamp: ~U[2024-01-15 14:30:00.123456Z],
  bid_exchange: "NASDAQ",
  ask_exchange: "NASDAQ"
}
```

#### Trade
```elixir
%{
  type: :trade,
  symbol: "AAPL",
  price: #Decimal<185.51>,
  size: 100,
  timestamp: ~U[2024-01-15 14:30:00.123456Z],
  exchange: "NASDAQ"
}
```

## Testing

Run the test suite:

```bash
# Run unit tests (no credentials required)
mix test

# Run all tests including integration tests (requires valid credentials)
mix test --include integration
```

For integration tests, make sure your environment variables are set:

```bash
export ALPACA_API_KEY="your-key"
export ALPACA_API_SECRET="your-secret"
mix test --include integration
```

## Error Handling

All functions return `{:ok, result}` or `{:error, reason}` tuples:

```elixir
case AlpacaEx.Client.get_account() do
  {:ok, account} ->
    # Handle success
    IO.inspect(account)

  {:error, :unauthorized} ->
    # Invalid credentials
    IO.puts("Check your API credentials")

  {:error, :forbidden} ->
    # Insufficient permissions
    IO.puts("Check your API key permissions")

  {:error, :not_found} ->
    # Resource not found
    IO.puts("Resource not found")

  {:error, :rate_limit_exceeded} ->
    # Too many requests
    IO.puts("Rate limit exceeded, try again later")

  {:error, {:server_error, status, body}} ->
    # Server error (5xx)
    IO.puts("Server error: #{status}")

  {:error, {:network_error, reason}} ->
    # Network error
    IO.puts("Network error: #{inspect(reason)}")
end
```

## Documentation

Generate and view the documentation:

```bash
mix docs
open doc/index.html
```

Online documentation: [https://hexdocs.pm/alpaca_ex](https://hexdocs.pm/alpaca_ex)

## Examples

See the [examples](examples/) directory for complete example applications:

- `examples/simple_trader.ex` - Basic trading bot
- `examples/market_data_logger.ex` - Log real-time market data
- `examples/portfolio_tracker.ex` - Track portfolio performance

## Roadmap

- [ ] Order status streaming via WebSocket
- [ ] Crypto trading support
- [ ] Options trading support
- [ ] News API integration
- [ ] Portfolio analytics helpers

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.

## Resources

- [Alpaca Markets](https://alpaca.markets/)
- [Alpaca API Documentation](https://alpaca.markets/docs/)
- [Alpaca Discord Community](https://alpaca.markets/discord)

## Disclaimer

This library is not officially associated with Alpaca Markets. Use at your own risk.

Trading stocks involves risk. This library is provided "as is" without warranty of any kind. The authors are not responsible for any losses incurred from using this library.

Always test your strategies with paper trading before using real money.
