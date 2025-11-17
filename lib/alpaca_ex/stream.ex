defmodule AlpacaEx.Stream do
  @moduledoc """
  WebSocket client for real-time market data streaming from Alpaca Markets.

  This module provides a GenServer-based WebSocket client that connects to
  Alpaca's data streaming service and delivers real-time market data to a
  callback module.

  ## Callback Module

  Your application must implement a callback module with the following function:

      @callback handle_message(message :: map(), state :: any()) :: {:ok, new_state :: any()}

  The callback will receive normalized messages with the following structure:

  - **Quote**: `%{type: :quote, symbol: "AAPL", bid_price: 185.50, bid_size: 100, ...}`
  - **Bar**: `%{type: :bar, symbol: "AAPL", open: 185.20, high: 185.60, ...}`
  - **Trade**: `%{type: :trade, symbol: "AAPL", price: 185.50, size: 100, ...}`
  - **Status**: `%{type: :status, symbol: "AAPL", status_code: "T", ...}`
  - **Connection**: `%{type: :connection, status: :connected, ...}`

  ## Usage Example

      defmodule MyApp.MarketDataHandler do
        def handle_message(%{type: :bar, symbol: symbol, close: close}, state) do
          IO.puts("Bar: \#{symbol} closed at $\#{close}")
          {:ok, state}
        end

        def handle_message(%{type: :quote, symbol: symbol, ask_price: ask}, state) do
          IO.puts("Quote: \#{symbol} ask $\#{ask}")
          {:ok, state}
        end

        def handle_message(_message, state) do
          {:ok, state}
        end
      end

      {:ok, pid} = AlpacaEx.Stream.start_link(
        callback_module: MyApp.MarketDataHandler,
        callback_state: %{},
        name: MyApp.Stream
      )

      AlpacaEx.Stream.subscribe(pid, %{
        bars: ["AAPL", "TSLA"],
        quotes: ["AAPL"]
      })

  ## Automatic Reconnection

  The stream will automatically reconnect with exponential backoff if the
  connection is lost. All subscriptions will be restored after reconnection.
  """

  use WebSockex
  require Logger

  @max_backoff 60_000
  @initial_backoff 1_000

  # Client API

  @doc """
  Starts the stream WebSocket client.

  ## Options

  - `:callback_module` (required) - Module implementing `handle_message/2`
  - `:callback_state` - Initial state passed to callbacks (default: `nil`)
  - `:name` - Process name for registration

  ## Examples

      {:ok, pid} = AlpacaEx.Stream.start_link(
        callback_module: MyHandler,
        callback_state: %{},
        name: MyApp.Stream
      )

  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    callback_module = Keyword.fetch!(opts, :callback_module)
    callback_state = Keyword.get(opts, :callback_state)
    name = Keyword.get(opts, :name)

    state = %{
      callback_module: callback_module,
      callback_state: callback_state,
      status: :connecting,
      subscriptions: %{bars: [], quotes: [], trades: [], statuses: []},
      reconnect_attempt: 0
    }

    ws_url = AlpacaEx.Config.ws_url()

    websockex_opts =
      if name do
        [name: name, async: true]
      else
        [async: true]
      end

    WebSockex.start_link(ws_url, __MODULE__, state, websockex_opts)
  end

  @doc """
  Subscribes to real-time data streams.

  ## Parameters

  - `pid` - Stream process pid or name
  - `subscriptions` - Map with subscription types:
    - `:bars` - List of symbols for bar updates
    - `:quotes` - List of symbols for quote updates
    - `:trades` - List of symbols for trade updates
    - `:statuses` - List of symbols for status updates

  ## Examples

      AlpacaEx.Stream.subscribe(pid, %{
        bars: ["AAPL", "TSLA"],
        quotes: ["AAPL"]
      })

  """
  @spec subscribe(pid() | atom(), map()) :: :ok
  def subscribe(pid, subscriptions) when is_map(subscriptions) do
    WebSockex.cast(pid, {:subscribe, subscriptions})
  end

  @doc """
  Unsubscribes from data streams.

  ## Examples

      AlpacaEx.Stream.unsubscribe(pid, %{bars: ["AAPL"]})

  """
  @spec unsubscribe(pid() | atom(), map()) :: :ok
  def unsubscribe(pid, subscriptions) when is_map(subscriptions) do
    WebSockex.cast(pid, {:unsubscribe, subscriptions})
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.debug("WebSocket connection established")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, message}, state) do
    new_state = handle_websocket_message(message, state)
    {:ok, new_state}
  end

  @impl true
  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_frame, json}, state) do
    {:reply, {:text, json}, state}
  end

  @impl true
  def handle_cast({:subscribe, new_subs}, state) do
    # Merge new subscriptions with existing ones
    updated_subs = merge_subscriptions(state.subscriptions, new_subs)

    # If we're authenticated, send subscribe message
    new_state =
      if state.status in [:authenticated, :subscribed] do
        send_subscribe(new_subs, state)
        %{state | subscriptions: updated_subs, status: :subscribed}
      else
        # Queue the subscriptions for when we connect
        %{state | subscriptions: updated_subs}
      end

    {:ok, new_state}
  end

  @impl true
  def handle_cast({:unsubscribe, remove_subs}, state) do
    # Remove subscriptions
    updated_subs = remove_subscriptions(state.subscriptions, remove_subs)

    # If we're authenticated, send unsubscribe message
    if state.status in [:authenticated, :subscribed] do
      send_unsubscribe(remove_subs, state)
    end

    {:ok, %{state | subscriptions: updated_subs}}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("WebSocket disconnected: #{inspect(reason)}")

    notify_callback(state, %{
      type: :connection,
      status: :disconnected,
      attempt: state.reconnect_attempt
    })

    backoff = calculate_backoff(state.reconnect_attempt)
    new_state = %{state | status: :disconnected, reconnect_attempt: state.reconnect_attempt + 1}

    {:reconnect, backoff, new_state}
  end

  @impl true
  def handle_ping(:ping, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_pong(:pong, state) do
    {:ok, state}
  end

  # Private Functions

  defp calculate_backoff(attempt) do
    backoff = @initial_backoff * :math.pow(2, attempt) |> trunc()
    min(backoff, @max_backoff)
  end

  defp handle_websocket_message(message, state) do
    case Jason.decode(message) do
      {:ok, messages} when is_list(messages) ->
        Enum.reduce(messages, state, fn msg, acc_state ->
          process_message(msg, acc_state)
        end)

      {:ok, msg} when is_map(msg) ->
        process_message(msg, state)

      {:error, error} ->
        Logger.error("Failed to parse WebSocket message: #{inspect(error)}")
        state
    end
  end

  defp process_message(%{"T" => "success", "msg" => "connected"}, state) do
    Logger.info("Connected to Alpaca stream")
    # Send authentication
    send_auth(state)
    %{state | status: :connected}
  end

  defp process_message(%{"T" => "success", "msg" => "authenticated"}, state) do
    Logger.info("Authenticated with Alpaca stream")

    # Send pending subscriptions if any
    if has_subscriptions?(state.subscriptions) do
      send_subscribe(state.subscriptions, state)
      %{state | status: :subscribed}
    else
      %{state | status: :authenticated}
    end
  end

  defp process_message(%{"T" => "subscription"} = msg, state) do
    Logger.debug("Subscription confirmed: #{inspect(msg)}")

    notify_callback(state, %{
      type: :connection,
      status: :subscribed,
      subscriptions: state.subscriptions
    })

    state
  end

  defp process_message(%{"T" => "error"} = msg, state) do
    Logger.error("Error from Alpaca stream: #{inspect(msg)}")
    state
  end

  # Quote message
  defp process_message(%{"T" => "q"} = msg, state) do
    quote = %{
      type: :quote,
      symbol: msg["S"],
      bid_price: parse_decimal(msg["bp"]),
      bid_size: msg["bs"],
      ask_price: parse_decimal(msg["ap"]),
      ask_size: msg["as"],
      timestamp: parse_datetime(msg["t"]),
      bid_exchange: msg["bx"],
      ask_exchange: msg["ax"],
      conditions: msg["c"]
    }

    notify_callback(state, quote)
    state
  end

  # Bar message
  defp process_message(%{"T" => "b"} = msg, state) do
    bar = %{
      type: :bar,
      symbol: msg["S"],
      open: parse_decimal(msg["o"]),
      high: parse_decimal(msg["h"]),
      low: parse_decimal(msg["l"]),
      close: parse_decimal(msg["c"]),
      volume: msg["v"],
      timestamp: parse_datetime(msg["t"]),
      vwap: parse_decimal(msg["vw"]),
      trade_count: msg["n"]
    }

    notify_callback(state, bar)
    state
  end

  # Trade message
  defp process_message(%{"T" => "t"} = msg, state) do
    trade = %{
      type: :trade,
      symbol: msg["S"],
      price: parse_decimal(msg["p"]),
      size: msg["s"],
      timestamp: parse_datetime(msg["t"]),
      exchange: msg["x"],
      conditions: msg["c"],
      id: msg["i"]
    }

    notify_callback(state, trade)
    state
  end

  # Status message
  defp process_message(%{"T" => "s"} = msg, state) do
    status_msg = %{
      type: :status,
      symbol: msg["S"],
      status_code: msg["sc"],
      status_message: msg["sm"],
      reason_code: msg["rc"],
      reason_message: msg["rm"],
      timestamp: parse_datetime(msg["t"])
    }

    notify_callback(state, status_msg)
    state
  end

  # Unknown message type
  defp process_message(msg, state) do
    Logger.debug("Unknown message type: #{inspect(msg)}")
    state
  end

  defp send_auth(_state) do
    auth_msg = %{
      action: "auth",
      key: AlpacaEx.Config.api_key!(),
      secret: AlpacaEx.Config.api_secret!()
    }

    send_frame_async(auth_msg)
  end

  defp send_subscribe(subscriptions, _state) do
    # Filter out empty subscription lists
    filtered_subs =
      subscriptions
      |> Enum.filter(fn {_key, values} -> values != [] end)
      |> Enum.into(%{})

    if filtered_subs != %{} do
      msg = Map.put(filtered_subs, :action, "subscribe")
      send_frame_async(msg)
    end
  end

  defp send_unsubscribe(subscriptions, _state) do
    filtered_subs =
      subscriptions
      |> Enum.filter(fn {_key, values} -> values != [] end)
      |> Enum.into(%{})

    if filtered_subs != %{} do
      msg = Map.put(filtered_subs, :action, "unsubscribe")
      send_frame_async(msg)
    end
  end

  defp send_frame_async(data) do
    case Jason.encode(data) do
      {:ok, json} ->
        WebSockex.cast(self(), {:send_frame, json})

      {:error, error} ->
        Logger.error("Failed to encode JSON: #{inspect(error)}")
    end
  end

  defp merge_subscriptions(existing, new) do
    Map.merge(existing, new, fn _key, old_list, new_list ->
      Enum.uniq(old_list ++ new_list)
    end)
  end

  defp remove_subscriptions(existing, to_remove) do
    Map.merge(existing, to_remove, fn _key, old_list, remove_list ->
      old_list -- remove_list
    end)
  end

  defp has_subscriptions?(subs) do
    Enum.any?(subs, fn {_key, values} -> values != [] end)
  end

  defp notify_callback(state, message) do
    case state.callback_module.handle_message(message, state.callback_state) do
      {:ok, new_callback_state} ->
        %{state | callback_state: new_callback_state}

      other ->
        Logger.warning(
          "Callback returned unexpected value: #{inspect(other)}. Expected {:ok, state}"
        )

        state
    end
  rescue
    error ->
      Logger.error("Error in callback: #{inspect(error)}")
      state
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(value) when is_number(value) do
    Decimal.from_float(value)
  end
end
