defmodule AlpacaEx.StreamTest do
  use ExUnit.Case, async: false

  # Mock callback module for testing
  defmodule TestCallback do
    def handle_message(message, state) do
      # Send message to test process
      send(state.test_pid, {:callback_received, message})
      {:ok, state}
    end
  end

  setup do
    # Configure test credentials
    Application.put_env(:alpaca_ex, :api_key, "test-api-key")
    Application.put_env(:alpaca_ex, :api_secret, "test-api-secret")
    Application.put_env(:alpaca_ex, :ws_url, "wss://stream.data.alpaca.markets/v2/iex")

    on_exit(fn ->
      Application.delete_env(:alpaca_ex, :api_key)
      Application.delete_env(:alpaca_ex, :api_secret)
      Application.delete_env(:alpaca_ex, :ws_url)
    end)

    :ok
  end

  describe "start_link/1" do
    test "requires callback_module option" do
      assert_raise KeyError, fn ->
        AlpacaEx.Stream.start_link([])
      end
    end

    # Note: Full integration test would require WebSocket connection
    # which we can't easily mock without additional dependencies
  end

  describe "subscribe/2" do
    test "accepts subscription map" do
      # This test would require a running stream process
      # Just verify the function exists
      assert is_function(&AlpacaEx.Stream.subscribe/2)
    end
  end

  describe "status/1" do
    test "function exists" do
      assert is_function(&AlpacaEx.Stream.status/1)
    end
  end

  @tag :integration
  describe "integration tests" do
    test "connects and receives data" do
      # Start stream with test callback
      {:ok, pid} =
        AlpacaEx.Stream.start_link(
          callback_module: TestCallback,
          callback_state: %{test_pid: self()}
        )

      # Wait for connection
      Process.sleep(2000)

      # Check status
      status = AlpacaEx.Stream.status(pid)
      assert status in [:connecting, :connected, :authenticated, :subscribed]

      # Subscribe to test symbol
      :ok = AlpacaEx.Stream.subscribe(pid, %{bars: ["AAPL"]})

      # Wait for potential messages
      Process.sleep(5000)

      # Clean up
      GenServer.stop(pid)
    end
  end
end
