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

  use GenServer
  require Logger

  @max_backoff 60_000
  @initial_backoff 1_000

  # Client API

  @doc """
  Starts the stream GenServer.

  ## Options

  - `:callback_module` (required) - Module implementing `handle_message/2`
  - `:callback_state` - Initial state passed to callbacks (default: `nil`)
  - `:name` - GenServer name for registration
  - `:skip_connect` - Skip automatic connection on startup (default: `false`, useful for testing)

  ## Examples

      {:ok, pid} = AlpacaEx.Stream.start_link(
        callback_module: MyHandler,
        callback_state: %{},
        name: MyApp.Stream
      )

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Subscribes to real-time data streams.

  ## Parameters

  - `pid` - Stream GenServer pid or name
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
  @spec subscribe(GenServer.server(), map()) :: :ok
  def subscribe(pid, subscriptions) when is_map(subscriptions) do
    GenServer.call(pid, {:subscribe, subscriptions})
  end

  @doc """
  Unsubscribes from data streams.

  ## Examples

      AlpacaEx.Stream.unsubscribe(pid, %{bars: ["AAPL"]})

  """
  @spec unsubscribe(GenServer.server(), map()) :: :ok
  def unsubscribe(pid, subscriptions) when is_map(subscriptions) do
    GenServer.call(pid, {:unsubscribe, subscriptions})
  end

  @doc """
  Gets the current connection status.

  Returns one of: `:disconnected`, `:connecting`, `:connected`, `:authenticated`, `:subscribed`

  ## Examples

      AlpacaEx.Stream.status(pid)
      #=> :subscribed

  """
  @spec status(GenServer.server()) :: atom()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Gets current subscriptions.

  ## Examples

      AlpacaEx.Stream.subscriptions(pid)
      #=> %{bars: ["AAPL"], quotes: ["AAPL", "TSLA"]}

  """
  @spec subscriptions(GenServer.server()) :: map()
  def subscriptions(pid) do
    GenServer.call(pid, :subscriptions)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    callback_module = Keyword.fetch!(opts, :callback_module)
    callback_state = Keyword.get(opts, :callback_state)
    skip_connect = Keyword.get(opts, :skip_connect, false)

    state = %{
      callback_module: callback_module,
      callback_state: callback_state,
      ws_pid: nil,
      status: :disconnected,
      subscriptions: %{bars: [], quotes: [], trades: [], statuses: []},
      reconnect_attempt: 0
    }

    # Connect immediately unless skip_connect is true
    if skip_connect do
      {:ok, state}
    else
      {:ok, state, {:continue, :connect}}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, ws_pid} ->
        new_state = %{state | ws_pid: ws_pid, status: :connecting, reconnect_attempt: 0}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}")
        schedule_reconnect(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:subscribe, new_subs}, _from, state) do
    # Merge new subscriptions with existing ones
    updated_subs = merge_subscriptions(state.subscriptions, new_subs)

    # If we're authenticated, send subscribe message
    new_state =
      if state.status in [:authenticated, :subscribed] do
        send_subscribe(state.ws_pid, new_subs)
        %{state | subscriptions: updated_subs, status: :subscribed}
      else
        # Queue the subscriptions for when we connect
        %{state | subscriptions: updated_subs}
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unsubscribe, remove_subs}, _from, state) do
    # Remove subscriptions
    updated_subs = remove_subscriptions(state.subscriptions, remove_subs)

    # If we're authenticated, send unsubscribe message
    if state.status in [:authenticated, :subscribed] do
      send_unsubscribe(state.ws_pid, remove_subs)
    end

    {:reply, :ok, %{state | subscriptions: updated_subs}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  @impl true
  def handle_info({:ssl_closed, _}, state) do
    Logger.warning("SSL connection closed")
    handle_disconnect(state)
  end

  @impl true
  def handle_info(:reconnect, state) do
    case connect(state) do
      {:ok, ws_pid} ->
        new_state = %{state | ws_pid: ws_pid, status: :connecting}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Reconnection failed: #{inspect(reason)}")
        schedule_reconnect(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:websocket, ws_pid, {:text, message}}, %{ws_pid: ws_pid} = state) do
    new_state = handle_websocket_message(message, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, ws_pid, reason}, %{ws_pid: ws_pid} = state) do
    Logger.warning("WebSocket process down: #{inspect(reason)}")
    handle_disconnect(state)
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp connect(state) do
    ws_url = AlpacaEx.Config.ws_url()

    # Add GenServer PID to state so WebSocket callbacks can send messages back
    ws_state = Map.put(state, :genserver_pid, self())

    case WebSockex.start_link(ws_url, __MODULE__, ws_state, handle_initial_conn_failure: true) do
      {:ok, pid} ->
        # Monitor the WebSocket process
        Process.monitor(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  defp handle_disconnect(state) do
    notify_callback(state, %{
      type: :connection,
      status: :disconnected,
      attempt: state.reconnect_attempt
    })

    schedule_reconnect(state)
    {:noreply, %{state | status: :disconnected, ws_pid: nil}}
  end

  defp schedule_reconnect(state) do
    backoff = calculate_backoff(state.reconnect_attempt)
    Logger.info("Scheduling reconnect in #{backoff}ms")
    Process.send_after(self(), :reconnect, backoff)
    %{state | reconnect_attempt: state.reconnect_attempt + 1}
  end

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
    send_auth(state.ws_pid)
    %{state | status: :connected}
  end

  defp process_message(%{"T" => "success", "msg" => "authenticated"}, state) do
    Logger.info("Authenticated with Alpaca stream")

    # Send pending subscriptions if any
    if has_subscriptions?(state.subscriptions) do
      send_subscribe(state.ws_pid, state.subscriptions)
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

  defp send_auth(ws_pid) do
    auth_msg = %{
      action: "auth",
      key: AlpacaEx.Config.api_key!(),
      secret: AlpacaEx.Config.api_secret!()
    }

    send_json(ws_pid, auth_msg)
  end

  defp send_subscribe(ws_pid, subscriptions) do
    # Filter out empty subscription lists
    filtered_subs =
      subscriptions
      |> Enum.filter(fn {_key, values} -> values != [] end)
      |> Enum.into(%{})

    if filtered_subs != %{} do
      msg = Map.put(filtered_subs, :action, "subscribe")
      send_json(ws_pid, msg)
    end
  end

  defp send_unsubscribe(ws_pid, subscriptions) do
    filtered_subs =
      subscriptions
      |> Enum.filter(fn {_key, values} -> values != [] end)
      |> Enum.into(%{})

    if filtered_subs != %{} do
      msg = Map.put(filtered_subs, :action, "unsubscribe")
      send_json(ws_pid, msg)
    end
  end

  defp send_json(ws_pid, data) do
    case Jason.encode(data) do
      {:ok, json} ->
        WebSockex.send_frame(ws_pid, {:text, json})

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
    value |> to_string() |> Decimal.new()
  end

  # WebSockex Callbacks
  # These callbacks are used when this module is passed to WebSockex.start_link/4
  # We don't declare @behaviour WebSockex to avoid conflicts with GenServer callbacks

  def handle_frame({:text, msg}, state) do
    # Send message to the GenServer process, not to self (WebSocket process)
    send(state.genserver_pid, {:websocket, self(), {:text, msg}})
    {:ok, state}
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("WebSocket disconnected: #{inspect(reason)}")
    send(self(), {:websocket_disconnected, reason})
    {:ok, state}
  end

  def handle_connect(_conn, state) do
    {:ok, state}
  end

  def handle_ping(:ping, state) do
    {:reply, :pong, state}
  end

  def handle_pong(:pong, state) do
    {:ok, state}
  end

  # This implements both GenServer.terminate/2 and is used by WebSockex.terminate/2
  @impl true
  def terminate(reason, _state) do
    Logger.info("Process terminating: #{inspect(reason)}")
    :ok
  end
end

defmodule AlpacaEx.Stream.LogHandler do
  @moduledoc """
  A simple logging callback handler for AlpacaEx.Stream.

  This module logs all incoming messages to the console, which is useful
  for testing and debugging. It implements the callback interface required
  by `AlpacaEx.Stream`.

  ## Usage

      {:ok, pid} = AlpacaEx.Stream.start_link(
        callback_module: AlpacaEx.Stream.LogHandler,
        name: MyStream
      )

  """

  require Logger

  @doc """
  Handles incoming messages by logging them.
  """
  def handle_message(%{type: :connection, status: status} = msg, state) do
    case status do
      :connected ->
        Logger.info("✓ Connected to Alpaca stream")

      :subscribed ->
        Logger.info("✓ Subscribed: #{inspect(msg.subscriptions)}")

      :disconnected ->
        Logger.warning("⚠ Disconnected (attempt #{msg.attempt})")

      _ ->
        Logger.debug("Connection: #{inspect(msg)}")
    end

    {:ok, state}
  end

  def handle_message(%{type: :trade} = trade, state) do
    count = (state[:count] || 0) + 1
    time = format_time(trade.timestamp)

    Logger.info(
      "[#{count}] Trade: #{trade.symbol} @ $#{trade.price} x #{trade.size} (#{time})"
    )

    {:ok, Map.put(state || %{}, :count, count)}
  end

  def handle_message(%{type: :quote} = quote, state) do
    count = (state[:count] || 0) + 1
    time = format_time(quote.timestamp)

    Logger.info(
      "[#{count}] Quote: #{quote.symbol} - Bid: $#{quote.bid_price} / Ask: $#{quote.ask_price} (#{time})"
    )

    {:ok, Map.put(state || %{}, :count, count)}
  end

  def handle_message(%{type: :bar} = bar, state) do
    count = (state[:count] || 0) + 1
    time = format_time(bar.timestamp)

    Logger.info(
      "[#{count}] Bar: #{bar.symbol} - O:$#{bar.open} H:$#{bar.high} L:$#{bar.low} C:$#{bar.close} V:#{bar.volume} (#{time})"
    )

    {:ok, Map.put(state || %{}, :count, count)}
  end

  def handle_message(%{type: :status} = status, state) do
    Logger.info("Status: #{status.symbol} - #{status.status_code}: #{status.status_message}")
    {:ok, state}
  end

  def handle_message(msg, state) do
    Logger.debug("Unknown message: #{inspect(msg)}")
    {:ok, state}
  end

  defp format_time(nil), do: "N/A"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "N/A"
end
