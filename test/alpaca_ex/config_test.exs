defmodule AlpacaEx.ConfigTest do
  use ExUnit.Case, async: false

  setup do
    # Store original config
    original_config = Application.get_all_env(:alpaca_ex)

    on_exit(fn ->
      # Restore original config
      Application.put_all_env([{:alpaca_ex, original_config}])
    end)

    :ok
  end

  describe "api_key!/0" do
    test "returns configured API key" do
      Application.put_env(:alpaca_ex, :api_key, "test-key")
      assert AlpacaEx.Config.api_key!() == "test-key"
    end

    test "raises when API key not configured" do
      Application.delete_env(:alpaca_ex, :api_key)

      assert_raise RuntimeError, ~r/API key not configured/, fn ->
        AlpacaEx.Config.api_key!()
      end
    end

    test "raises when API key is empty" do
      Application.put_env(:alpaca_ex, :api_key, "")

      assert_raise RuntimeError, ~r/API key is configured but empty/, fn ->
        AlpacaEx.Config.api_key!()
      end
    end
  end

  describe "api_secret!/0" do
    test "returns configured API secret" do
      Application.put_env(:alpaca_ex, :api_secret, "test-secret")
      assert AlpacaEx.Config.api_secret!() == "test-secret"
    end

    test "raises when API secret not configured" do
      Application.delete_env(:alpaca_ex, :api_secret)

      assert_raise RuntimeError, ~r/API secret not configured/, fn ->
        AlpacaEx.Config.api_secret!()
      end
    end

    test "raises when API secret is empty" do
      Application.put_env(:alpaca_ex, :api_secret, "")

      assert_raise RuntimeError, ~r/API secret is configured but empty/, fn ->
        AlpacaEx.Config.api_secret!()
      end
    end
  end

  describe "base_url/0" do
    test "returns configured base URL" do
      Application.put_env(:alpaca_ex, :base_url, "https://api.alpaca.markets")
      assert AlpacaEx.Config.base_url() == "https://api.alpaca.markets"
    end

    test "returns default when not configured" do
      Application.delete_env(:alpaca_ex, :base_url)
      assert AlpacaEx.Config.base_url() == "https://paper-api.alpaca.markets"
    end
  end

  describe "ws_url/0" do
    test "returns configured WebSocket URL" do
      Application.put_env(:alpaca_ex, :ws_url, "wss://stream.data.alpaca.markets/v2/sip")
      assert AlpacaEx.Config.ws_url() == "wss://stream.data.alpaca.markets/v2/sip"
    end

    test "returns default when not configured" do
      Application.delete_env(:alpaca_ex, :ws_url)
      assert AlpacaEx.Config.ws_url() == "wss://stream.data.alpaca.markets/v2/iex"
    end
  end

  describe "data_feed/0" do
    test "returns :iex for IEx feed" do
      Application.put_env(:alpaca_ex, :ws_url, "wss://stream.data.alpaca.markets/v2/iex")
      assert AlpacaEx.Config.data_feed() == :iex
    end

    test "returns :sip for SIP feed" do
      Application.put_env(:alpaca_ex, :ws_url, "wss://stream.data.alpaca.markets/v2/sip")
      assert AlpacaEx.Config.data_feed() == :sip
    end

    test "defaults to :iex for unknown feed" do
      Application.put_env(:alpaca_ex, :ws_url, "wss://unknown.url/v2/other")
      assert AlpacaEx.Config.data_feed() == :iex
    end
  end

  describe "configured?/0" do
    test "returns true when both credentials are configured" do
      Application.put_env(:alpaca_ex, :api_key, "test-key")
      Application.put_env(:alpaca_ex, :api_secret, "test-secret")
      assert AlpacaEx.Config.configured?() == true
    end

    test "returns false when API key is missing" do
      Application.delete_env(:alpaca_ex, :api_key)
      Application.put_env(:alpaca_ex, :api_secret, "test-secret")
      assert AlpacaEx.Config.configured?() == false
    end

    test "returns false when API secret is missing" do
      Application.put_env(:alpaca_ex, :api_key, "test-key")
      Application.delete_env(:alpaca_ex, :api_secret)
      assert AlpacaEx.Config.configured?() == false
    end

    test "returns false when credentials are empty strings" do
      Application.put_env(:alpaca_ex, :api_key, "")
      Application.put_env(:alpaca_ex, :api_secret, "")
      assert AlpacaEx.Config.configured?() == false
    end
  end

  describe "paper_trading?/0" do
    test "returns true for paper trading URL" do
      Application.put_env(:alpaca_ex, :base_url, "https://paper-api.alpaca.markets")
      assert AlpacaEx.Config.paper_trading?() == true
    end

    test "returns false for live trading URL" do
      Application.put_env(:alpaca_ex, :base_url, "https://api.alpaca.markets")
      assert AlpacaEx.Config.paper_trading?() == false
    end
  end

  describe "validate/0" do
    test "returns :ok when all config is valid" do
      Application.put_env(:alpaca_ex, :api_key, "test-key")
      Application.put_env(:alpaca_ex, :api_secret, "test-secret")
      Application.put_env(:alpaca_ex, :base_url, "https://paper-api.alpaca.markets")
      Application.put_env(:alpaca_ex, :ws_url, "wss://stream.data.alpaca.markets/v2/iex")

      assert AlpacaEx.Config.validate() == :ok
    end

    test "returns errors when credentials are missing" do
      Application.delete_env(:alpaca_ex, :api_key)
      Application.delete_env(:alpaca_ex, :api_secret)

      assert {:error, errors} = AlpacaEx.Config.validate()
      assert "API key not configured" in errors
      assert "API secret not configured" in errors
    end

    test "returns errors for invalid URLs" do
      Application.put_env(:alpaca_ex, :api_key, "test-key")
      Application.put_env(:alpaca_ex, :api_secret, "test-secret")
      Application.put_env(:alpaca_ex, :base_url, "invalid-url")
      Application.put_env(:alpaca_ex, :ws_url, "invalid-ws")

      assert {:error, errors} = AlpacaEx.Config.validate()
      assert "Base URL must start with http:// or https://" in errors
      assert "WebSocket URL must start with ws:// or wss://" in errors
    end
  end
end
