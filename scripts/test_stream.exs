#!/usr/bin/env elixir

# Quick test script for Alpaca streaming using the test endpoint
#
# Usage:
#   elixir scripts/test_stream.exs

Mix.install([
  {:alpaca_ex, path: Path.join(__DIR__, "..")}
])

# Configure for test stream
Application.put_env(:alpaca_ex, :api_key, System.get_env("ALPACA_API_KEY_ID") || "test")
Application.put_env(:alpaca_ex, :api_secret, System.get_env("ALPACA_API_SECRET_KEY") || "test")
Application.put_env(:alpaca_ex, :ws_url, "wss://stream.data.alpaca.markets/v2/test")

# Start stream with logging handler
{:ok, _pid} = AlpacaEx.Stream.start_link(
  callback_module: AlpacaEx.Stream.LogHandler,
  name: TestStream
)

# Subscribe to test data
AlpacaEx.Stream.subscribe(TestStream, %{
  trades: ["FAKEPACA"],
  quotes: ["FAKEPACA"],
  bars: ["FAKEPACA"]
})

IO.puts("""
========================================
Alpaca Test Stream
========================================
Using test endpoint with FAKEPACA symbol
Press Ctrl+C to stop...
========================================
""")

Process.sleep(:infinity)
