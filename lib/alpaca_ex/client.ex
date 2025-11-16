defmodule AlpacaEx.Client do
  @moduledoc """
  HTTP client for the Alpaca Markets REST API.

  This module provides functions for interacting with Alpaca's REST API,
  including market data retrieval, account management, and order execution.

  ## Authentication

  API requests are authenticated using headers configured in `AlpacaEx.Config`:
  - `APCA-API-KEY-ID`: Your API key
  - `APCA-API-SECRET-KEY`: Your API secret

  ## Rate Limiting

  Alpaca enforces rate limits on API requests. This module automatically
  retries requests that fail due to rate limiting (HTTP 429) with exponential
  backoff.

  ## Pagination

  Some endpoints return paginated results. This module automatically handles
  pagination and accumulates all results for you.

  ## Data Types

  - Prices are returned as `Decimal` for precision
  - Quantities are returned as integers
  - Timestamps are returned as `DateTime` structs
  """

  require Logger

  @max_retries 3
  @max_pagination_pages 100
  @initial_backoff 1000

  # Market Data API

  @doc """
  Gets historical bars (OHLCV data) for one or more symbols.

  ## Parameters

  - `symbols`: A single symbol string (e.g., "AAPL") or list of symbols
  - `opts`: Keyword list of options:
    - `:timeframe` - Bar timeframe (default: "1Min"). Options: "1Min", "5Min", "15Min", "1Hour", "1Day"
    - `:start` - Start time as DateTime (required)
    - `:end` - End time as DateTime (required)
    - `:limit` - Maximum bars per request (max 10000)
    - `:adjustment` - Price adjustment: "raw", "split", "dividend", "all"

  ## Returns

  - `{:ok, %{symbol => [bar_map]}}` - Map of symbols to lists of bars
  - `{:error, reason}` - Error tuple

  ## Examples

      {:ok, bars} = AlpacaEx.Client.get_bars("AAPL",
        timeframe: "1Min",
        start: ~U[2024-01-01 09:30:00Z],
        end: ~U[2024-01-01 16:00:00Z]
      )

      {:ok, multi_bars} = AlpacaEx.Client.get_bars(["AAPL", "TSLA"],
        timeframe: "1Hour",
        start: ~U[2024-01-01 00:00:00Z],
        end: ~U[2024-01-31 23:59:59Z]
      )

  """
  @spec get_bars(String.t() | [String.t()], keyword()) ::
          {:ok, %{String.t() => [map()]}} | {:error, term()}
  def get_bars(symbols, opts) when is_list(opts) do
    symbols_list = if is_binary(symbols), do: [symbols], else: symbols
    timeframe = Keyword.get(opts, :timeframe, "1Min")
    start_time = Keyword.fetch!(opts, :start)
    end_time = Keyword.fetch!(opts, :end)
    limit = Keyword.get(opts, :limit)
    adjustment = Keyword.get(opts, :adjustment)

    params =
      [
        symbols: Enum.join(symbols_list, ","),
        timeframe: timeframe,
        start: DateTime.to_iso8601(start_time),
        end: DateTime.to_iso8601(end_time)
      ]
      |> maybe_add_param(:limit, limit)
      |> maybe_add_param(:adjustment, adjustment)

    path = "/v2/stocks/bars"

    case get_paginated(path, params) do
      {:ok, %{"bars" => bars}} ->
        parsed_bars =
          Enum.into(bars, %{}, fn {symbol, bar_list} ->
            {symbol, Enum.map(bar_list, &parse_bar/1)}
          end)

        {:ok, parsed_bars}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets the latest bar for a symbol.

  ## Examples

      {:ok, bar} = AlpacaEx.Client.get_latest_bar("AAPL")

  """
  @spec get_latest_bar(String.t()) :: {:ok, map()} | {:error, term()}
  def get_latest_bar(symbol) do
    path = "/v2/stocks/#{symbol}/bars/latest"

    case get_request(path) do
      {:ok, %{"bar" => bar}} -> {:ok, parse_bar(bar)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Gets the latest quote for a symbol.

  ## Examples

      {:ok, quote} = AlpacaEx.Client.get_latest_quote("AAPL")

  """
  @spec get_latest_quote(String.t()) :: {:ok, map()} | {:error, term()}
  def get_latest_quote(symbol) do
    path = "/v2/stocks/#{symbol}/quotes/latest"

    case get_request(path) do
      {:ok, %{"quote" => quote}} -> {:ok, parse_quote(quote)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Gets the latest trade for a symbol.

  ## Examples

      {:ok, trade} = AlpacaEx.Client.get_latest_trade("AAPL")

  """
  @spec get_latest_trade(String.t()) :: {:ok, map()} | {:error, term()}
  def get_latest_trade(symbol) do
    path = "/v2/stocks/#{symbol}/trades/latest"

    case get_request(path) do
      {:ok, %{"trade" => trade}} -> {:ok, parse_trade(trade)}
      {:error, _} = error -> error
    end
  end

  # Account API

  @doc """
  Gets account information.

  ## Examples

      {:ok, account} = AlpacaEx.Client.get_account()

  """
  @spec get_account() :: {:ok, map()} | {:error, term()}
  def get_account do
    case get_request("/v2/account") do
      {:ok, account} -> {:ok, parse_account(account)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Gets all open positions.

  ## Examples

      {:ok, positions} = AlpacaEx.Client.get_positions()

  """
  @spec get_positions() :: {:ok, [map()]} | {:error, term()}
  def get_positions do
    case get_request("/v2/positions") do
      {:ok, positions} when is_list(positions) ->
        {:ok, Enum.map(positions, &parse_position/1)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets a position for a specific symbol.

  ## Examples

      {:ok, position} = AlpacaEx.Client.get_position("AAPL")

  """
  @spec get_position(String.t()) :: {:ok, map()} | {:error, term()}
  def get_position(symbol) do
    case get_request("/v2/positions/#{symbol}") do
      {:ok, position} -> {:ok, parse_position(position)}
      {:error, _} = error -> error
    end
  end

  # Orders API

  @doc """
  Lists orders with optional filters.

  ## Parameters

  - `opts`: Keyword list of filters:
    - `:status` - Order status: "open", "closed", "all"
    - `:limit` - Maximum number of orders
    - `:direction` - Sort direction: "asc", "desc"
    - `:symbols` - Filter by symbols (comma-separated string or list)

  ## Examples

      {:ok, orders} = AlpacaEx.Client.list_orders(status: "open")
      {:ok, orders} = AlpacaEx.Client.list_orders(status: "all", limit: 100)

  """
  @spec list_orders(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_orders(opts \\ []) do
    params =
      []
      |> maybe_add_param(:status, Keyword.get(opts, :status))
      |> maybe_add_param(:limit, Keyword.get(opts, :limit))
      |> maybe_add_param(:direction, Keyword.get(opts, :direction))
      |> maybe_add_symbols_param(Keyword.get(opts, :symbols))

    case get_request("/v2/orders", params) do
      {:ok, orders} when is_list(orders) ->
        {:ok, Enum.map(orders, &parse_order/1)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets a specific order by ID.

  ## Examples

      {:ok, order} = AlpacaEx.Client.get_order("order-id-123")

  """
  @spec get_order(String.t()) :: {:ok, map()} | {:error, term()}
  def get_order(order_id) do
    case get_request("/v2/orders/#{order_id}") do
      {:ok, order} -> {:ok, parse_order(order)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Places a new order.

  ## Parameters

  - `order`: Map with order parameters:
    - `:symbol` (required) - Symbol to trade
    - `:qty` - Quantity (integer) or `:notional` for dollar amount
    - `:notional` - Dollar amount for fractional shares
    - `:side` (required) - "buy" or "sell"
    - `:type` (required) - "market", "limit", "stop", "stop_limit"
    - `:time_in_force` (required) - "day", "gtc", "ioc", "fok"
    - `:limit_price` - Required for limit orders
    - `:stop_price` - Required for stop orders
    - `:extended_hours` - Allow extended hours trading (boolean)
    - `:client_order_id` - Client-specified order ID

  ## Examples

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
        limit_price: 150.00
      })

  """
  @spec place_order(map()) :: {:ok, map()} | {:error, term()}
  def place_order(order) when is_map(order) do
    # Convert limit_price and stop_price to strings if they're Decimal
    order =
      order
      |> convert_price_to_string(:limit_price)
      |> convert_price_to_string(:stop_price)

    case post_request("/v2/orders", order) do
      {:ok, order_response} -> {:ok, parse_order(order_response)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Cancels an order by ID.

  ## Examples

      {:ok, _} = AlpacaEx.Client.cancel_order("order-id-123")

  """
  @spec cancel_order(String.t()) :: {:ok, map()} | {:error, term()}
  def cancel_order(order_id) do
    delete_request("/v2/orders/#{order_id}")
  end

  @doc """
  Cancels all open orders.

  ## Examples

      {:ok, cancelled_orders} = AlpacaEx.Client.cancel_all_orders()

  """
  @spec cancel_all_orders() :: {:ok, [map()]} | {:error, term()}
  def cancel_all_orders do
    case delete_request("/v2/orders") do
      {:ok, orders} when is_list(orders) ->
        {:ok, Enum.map(orders, &parse_order/1)}

      {:error, _} = error ->
        error
    end
  end

  # Private helper functions

  defp get_request(path, params \\ []) do
    url = build_url(path, params)
    headers = build_headers()

    case Req.get(url, headers: headers, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 429} = response} ->
        handle_rate_limit(fn -> get_request(path, params) end, response, 0)

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:error, {:server_error, status, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, error} ->
        {:error, {:network_error, error}}
    end
  end

  defp post_request(path, body) do
    url = build_url(path)
    headers = build_headers()

    case Req.post(url, headers: headers, json: body, retry: false) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        {:ok, response_body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 429} = response} ->
        handle_rate_limit(fn -> post_request(path, body) end, response, 0)

      {:ok, %{status: status, body: response_body}} when status >= 500 ->
        {:error, {:server_error, status, response_body}}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, error} ->
        {:error, {:network_error, error}}
    end
  end

  defp delete_request(path) do
    url = build_url(path)
    headers = build_headers()

    case Req.delete(url, headers: headers, retry: false) do
      {:ok, %{status: status, body: body}} when status in [200, 204, 207] ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 429} = response} ->
        handle_rate_limit(fn -> delete_request(path) end, response, 0)

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:error, {:server_error, status, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, error} ->
        {:error, {:network_error, error}}
    end
  end

  defp get_paginated(path, initial_params, accumulated \\ %{}, page_count \\ 0)

  defp get_paginated(_path, _params, accumulated, page_count)
       when page_count >= @max_pagination_pages do
    Logger.warning("Reached maximum pagination limit of #{@max_pagination_pages} pages")
    {:ok, accumulated}
  end

  defp get_paginated(path, params, accumulated, page_count) do
    case get_request(path, params) do
      {:ok, response} ->
        # Merge the new data with accumulated data
        merged = merge_paginated_response(accumulated, response)

        # Check if there's a next page
        case Map.get(response, "next_page_token") do
          nil ->
            {:ok, merged}

          "" ->
            {:ok, merged}

          next_token ->
            new_params = Keyword.put(params, :page_token, next_token)
            get_paginated(path, new_params, merged, page_count + 1)
        end

      {:error, _} = error ->
        error
    end
  end

  defp merge_paginated_response(accumulated, response) when accumulated == %{} do
    response
  end

  defp merge_paginated_response(accumulated, response) do
    # Merge bars (or other data structures)
    bars = Map.get(response, "bars", %{})

    accumulated_bars = Map.get(accumulated, "bars", %{})

    merged_bars =
      Map.merge(accumulated_bars, bars, fn _key, old_list, new_list ->
        old_list ++ new_list
      end)

    Map.put(accumulated, "bars", merged_bars)
  end

  defp handle_rate_limit(_retry_fn, _response, attempt) when attempt >= @max_retries do
    {:error, :rate_limit_exceeded}
  end

  defp handle_rate_limit(retry_fn, response, attempt) do
    # Calculate backoff time (exponential backoff)
    backoff = @initial_backoff * :math.pow(2, attempt) |> trunc()

    # Check for Retry-After header
    backoff =
      case get_retry_after(response) do
        nil -> backoff
        retry_after -> retry_after * 1000
      end

    Logger.info("Rate limited, retrying after #{backoff}ms (attempt #{attempt + 1})")
    Process.sleep(backoff)
    retry_fn.()
  end

  defp get_retry_after(%{headers: headers}) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, [value]} when is_binary(value) -> String.to_integer(value)
      _ -> nil
    end
  end

  defp get_retry_after(_), do: nil

  defp build_url(path, params \\ []) do
    base_url = AlpacaEx.Config.base_url()
    url = base_url <> path

    if params == [] do
      url
    else
      query = URI.encode_query(params)
      url <> "?" <> query
    end
  end

  defp build_headers do
    [
      {"APCA-API-KEY-ID", AlpacaEx.Config.api_key!()},
      {"APCA-API-SECRET-KEY", AlpacaEx.Config.api_secret!()},
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]
  end

  # Response parsing functions

  defp parse_bar(bar) do
    %{
      timestamp: parse_datetime(bar["t"]),
      open: parse_decimal(bar["o"]),
      high: parse_decimal(bar["h"]),
      low: parse_decimal(bar["l"]),
      close: parse_decimal(bar["c"]),
      volume: bar["v"],
      vwap: parse_decimal(bar["vw"]),
      trade_count: bar["n"]
    }
  end

  defp parse_quote(quote) do
    %{
      timestamp: parse_datetime(quote["t"]),
      bid_price: parse_decimal(quote["bp"]),
      bid_size: quote["bs"],
      ask_price: parse_decimal(quote["ap"]),
      ask_size: quote["as"],
      bid_exchange: quote["bx"],
      ask_exchange: quote["ax"]
    }
  end

  defp parse_trade(trade) do
    %{
      timestamp: parse_datetime(trade["t"]),
      price: parse_decimal(trade["p"]),
      size: trade["s"],
      exchange: trade["x"],
      conditions: trade["c"]
    }
  end

  defp parse_account(account) do
    %{
      account_number: account["account_number"],
      status: account["status"],
      currency: account["currency"],
      buying_power: parse_decimal(account["buying_power"]),
      cash: parse_decimal(account["cash"]),
      portfolio_value: parse_decimal(account["portfolio_value"]),
      equity: parse_decimal(account["equity"]),
      last_equity: parse_decimal(account["last_equity"]),
      long_market_value: parse_decimal(account["long_market_value"]),
      short_market_value: parse_decimal(account["short_market_value"]),
      initial_margin: parse_decimal(account["initial_margin"]),
      maintenance_margin: parse_decimal(account["maintenance_margin"]),
      daytrade_count: account["daytrade_count"],
      daytrading_buying_power: parse_decimal(account["daytrading_buying_power"]),
      regt_buying_power: parse_decimal(account["regt_buying_power"])
    }
  end

  defp parse_position(position) do
    %{
      asset_id: position["asset_id"],
      symbol: position["symbol"],
      exchange: position["exchange"],
      asset_class: position["asset_class"],
      qty: parse_integer(position["qty"]),
      avg_entry_price: parse_decimal(position["avg_entry_price"]),
      side: position["side"],
      market_value: parse_decimal(position["market_value"]),
      cost_basis: parse_decimal(position["cost_basis"]),
      unrealized_pl: parse_decimal(position["unrealized_pl"]),
      unrealized_plpc: parse_decimal(position["unrealized_plpc"]),
      unrealized_intraday_pl: parse_decimal(position["unrealized_intraday_pl"]),
      unrealized_intraday_plpc: parse_decimal(position["unrealized_intraday_plpc"]),
      current_price: parse_decimal(position["current_price"]),
      lastday_price: parse_decimal(position["lastday_price"]),
      change_today: parse_decimal(position["change_today"])
    }
  end

  defp parse_order(order) do
    %{
      id: order["id"],
      client_order_id: order["client_order_id"],
      created_at: parse_datetime(order["created_at"]),
      updated_at: parse_datetime(order["updated_at"]),
      submitted_at: parse_datetime(order["submitted_at"]),
      filled_at: parse_datetime(order["filled_at"]),
      expired_at: parse_datetime(order["expired_at"]),
      canceled_at: parse_datetime(order["canceled_at"]),
      failed_at: parse_datetime(order["failed_at"]),
      asset_id: order["asset_id"],
      symbol: order["symbol"],
      qty: parse_decimal(order["qty"]),
      filled_qty: parse_decimal(order["filled_qty"]),
      type: order["type"],
      side: order["side"],
      time_in_force: order["time_in_force"],
      limit_price: parse_decimal(order["limit_price"]),
      stop_price: parse_decimal(order["stop_price"]),
      filled_avg_price: parse_decimal(order["filled_avg_price"]),
      status: order["status"],
      extended_hours: order["extended_hours"],
      legs: order["legs"]
    }
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

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Keyword.put(params, key, value)

  defp maybe_add_symbols_param(params, nil), do: params

  defp maybe_add_symbols_param(params, symbols) when is_list(symbols) do
    Keyword.put(params, :symbols, Enum.join(symbols, ","))
  end

  defp maybe_add_symbols_param(params, symbols) when is_binary(symbols) do
    Keyword.put(params, :symbols, symbols)
  end

  defp convert_price_to_string(order, key) do
    case Map.get(order, key) do
      nil ->
        order

      %Decimal{} = decimal ->
        Map.put(order, key, Decimal.to_string(decimal))

      value when is_number(value) ->
        Map.put(order, key, to_string(value))

      _ ->
        order
    end
  end
end
