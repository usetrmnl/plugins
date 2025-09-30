module Plugins
  class StockPrice < Base
    TICKER_NAME_DATA = JSON.parse(File.read("db/data/ticker-name.json"))
    STOCK_TICKER_LIMIT = 12.freeze

    SUPPORTED_INDEX = [
      'VIX', 'MXACW', 'XWLD', 'MXUSA', 'MXEF', 'MXEA', 'DJI', 'RUI', 'RUT', 'OEX', 'OEX', 'SPX', 'XSP', 'XSP', 'SPESG', 'XND', 'IXIC'
    ].freeze

    SUPPORTED_METAL = ['XAG', 'XAU', 'XPD', 'HG'].freeze

    def locals = { tickers:, currency_symbol:, currency_separator: }

    private

    def tickers
      ticker_data = string_to_array(settings["symbol"], limit: STOCK_TICKER_LIMIT).map do |symbol|
        ticker_price(symbol.upcase)
      end.compact

      ticker_data.each do |stock|
        stock[:price] = localized_price(stock[:price])
      end
    end

    def invalid_symbol(symbol)
      {
        symbol: symbol,
        name: 'SYMBOL_NOT_SUPPORTED',
        price: 0,
        change: ''
      }
    end

    def ticker_name(symbol) = TICKER_NAME_DATA[symbol]

    def ticker_price(symbol)
      Rails.cache.fetch "STOCK_PRICE_#{symbol}_extended_#{extended_hours?}_v2", expire_in: 15.minutes, skip_nil: true do
        if SUPPORTED_INDEX.include?(symbol)
          response = fetch(index_url(symbol), headers:)
          format_data(response, symbol)
        elsif SUPPORTED_METAL.include?(symbol.upcase.gsub!('USD', ''))
          response = fetch(metal_url(symbol), headers:)
          format_metal_data(response, symbol)
        else
          response = fetch(stock_url(symbol), headers:)
          format_data(response, symbol)
        end
      end
    end

    def format_metal_data(response, symbol)
      {
        symbol: symbol,
        name: response['name'],
        price: response['price'],
        change: "N/A"
      }
    end

    def format_data(response, symbol)
      if %w[error no_data].include?(response['s'])
        invalid_symbol(symbol)
      else
        {
          symbol: symbol.upcase,
          name: ticker_name(symbol.upcase),
          price: response.dig("last", 0),
          change: "#{(response.dig('changepct', 0).to_f * 100)&.round(2)}%"
        }
      end
    end

    def localized_price(base_price)
      (base_price * currency_conversions[currency])&.round(2)
    end

    def currency = settings['currency'].upcase

    def currency_symbol
      {
        'USD' => '$',
        'EUR' => '€',
        'CAD' => '$',
        'CHF' => '₣',
        'GBP' => '£',
        'KRW' => '₩',
        'CNY' => '¥',
        'JPY' => '¥',
        'INR' => '₹',
        'ZAR' => 'R',
        'CLP' => '$'
      }[currency]
    end

    def currency_separator
      case currency
      when 'EUR'
        ','
      else
        '.'
      end
    end

    def currency_conversions
      Rails.cache.fetch "STOCK_PRICE_CURRENCIES_#{supported_currencies.count}_VALUES", expire_in: 1.day, skip_nil: true do
        resp = HTTParty.get(currency_conversion_url)
        JSON.parse(resp.body)['data'].map { |k, v| { k => v['value'] } }.reduce({}, :merge)
      rescue StandardError
        nil
      end
    end

    def supported_currencies
      plugin.account_fields.find { |af| af['keyname'] == 'currency' }&.dig('options')
    end

    def extended_hours?
      settings['extended_hours'] == 'yes'
    end

    def stock_url(symbol) = "https://api.marketdata.app/v1/stocks/quotes/#{CGI.escape(symbol)}/?extended=#{extended_hours?}"

    def index_url(symbol) = "https://api.marketdata.app/v1/indices/quotes/#{CGI.escape(symbol)}/?extended=#{extended_hours?}"

    def metal_url(symbol) = "https://api.gold-api.com/price/#{symbol.gsub!('USD', '')}"

    def currency_conversion_url = "https://api.currencyapi.com/v3/latest?apikey=#{Rails.application.credentials.plugins.currency_api}&currencies=#{supported_currencies.join('%2C')}"

    def headers
      {
        Accept: "application/json",
        Authorization: "Token #{Rails.application.credentials.plugins[:marketdata_app]}"
      }
    end
  end
end
