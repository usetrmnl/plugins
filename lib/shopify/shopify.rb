module Plugins
  class Shopify < Base

    def locals
      { metrics:, histogram:, currency:, comparison_period: comparison_period.map { it.to_date.to_s } }
    end

    private

    def metrics
      kpi = {}
      kpi[:open_order_count] = fetch_order_count('open')
      kpi[:closed_order_count] = fetch_order_count('closed')

      total_orders = kpi[:open_order_count] + kpi[:closed_order_count]

      if total_orders.positive?
        fetch_orders
        kpi[:order_sales] = calculate_sale_value || 0
        kpi[:aov] = (kpi[:order_sales] / (kpi[:open_order_count] + kpi[:closed_order_count])).round(2)
      end

      kpi
    rescue InvalidURL
      { errors: "Invalid Store Web Address or Access Token" }
    end

    def fetch_orders
      @orders ||= query_sales_orders(lookback_period.to_s, nil)
      @comparison_orders ||= query_sales_orders(*comparison_period)
    end

    def histogram
      return { current: [], comparison: [] } if @orders.nil?

      current = prepare_charting_data(@orders)
      comparison = prepare_charting_data(@comparison_orders)
      comparison = normalize_with_current(comparison, current)

      { current:, comparison: }
    end

    def prepare_charting_data(orders)
      return [] if orders.nil? || orders.empty?

      order_data = orders&.map { { date: Date.parse(it['created_at']).to_s, value: it['current_subtotal_price'].to_f } }
                         &.group_by { it[:date] }
                         &.map { |k, v| { date: k, value: v.sum { it[:value] }.round(2) } }

      dates = order_data.map { it[:date] }

      min_date = Date.parse(dates.min)
      max_date = Date.parse(dates.max)

      all_dates_hash = (min_date..max_date).each_with_object({}) do |date, hash|
        hash[date.to_s] = { date: date.to_s, value: 0.0 }
      end

      order_data.each do |order|
        all_dates_hash[order[:date]] = order
      end

      all_dates_hash.values.sort_by { it[:date] }
    end

    def normalize_with_current(comparison, current)
      normalized_data = []
      case settings['lookback_period']
      when 'last_7_days'
        current.each_with_index do |data, index|
          next if comparison[index].nil?

          normalized_data.push({ date: data[:date], value: comparison[index][:value] })
        end
      else
        current.each do |data|
          selected_date = comparison.select { (Date.parse(it[:date]) + 1.month).to_s == data[:date] }.first
          next unless selected_date

          normalized_data.push({ date: data[:date], value: selected_date[:value] })
        end
      end

      normalized_data
    end

    def calculate_sale_value
      @orders&.sum { |o| o['current_subtotal_price'].to_f }
    end

    def lookback_period
      case settings['lookback_period']
      when 'last_7_days'
        (user.datetime_now - 7.days).iso8601
      when 'last_30_days'
        (user.datetime_now - 30.days).iso8601
      when 'month_to_date'
        user.datetime_now.beginning_of_month.iso8601
      end
    end

    def comparison_period
      case settings['lookback_period']
      when 'last_7_days'
        [(user.datetime_now - 14.days).iso8601, (user.datetime_now - 7.days).iso8601]
      when 'last_30_days'
        [(user.datetime_now - 60.days).iso8601, (user.datetime_now - 30.days).iso8601]
      when 'month_to_date'
        [(user.datetime_now.beginning_of_month - 1.month).iso8601, (user.datetime_now - 1.month).iso8601]
      end
    end

    def fetch_order_count(status = 'any')
      client.get(
        path: 'orders/count',
        query: {
          status: status,
          created_at_min: ">=#{lookback_period}"
        }
      ).body['count']
    rescue ShopifyAPI::Errors::HttpResponseError => e
      error_message = e.response.body['errors']
      raise InvalidURL if error_message.include?('Not Found') || error_message.include?('Invalid API key or access token')
    end

    def query_sales_orders(start_window, end_window)
      orders = []
      run_loop = true

      while run_loop
        retrieved_orders = client.get(
          path: 'orders',
          query: {
            status: 'any',
            limit: 250,
            created_at_min: start_window,
            processed_at_max: orders&.last&.dig('created_at') || end_window
          }
        ).body['orders']
        run_loop = false if retrieved_orders.count < 250
        orders += retrieved_orders.reject { |m| m['cancelled_at'].present? }
      end

      orders
    end

    def currency
      code = client.get(path: 'shop').body['shop']['currency']

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
        'ZAR' => 'R'
      }[code] || '$'
    rescue ShopifyAPI::Errors::HttpResponseError => e
      error_message = e.response.body['errors']
      raise InvalidURL if error_message.include?('Not Found') || error_message.include?('Invalid API key or access token')
    end

    def client = ShopifyAPI::Clients::Rest::Admin.new(session:)

    def session = ShopifyAPI::Auth::Session.new(shop:, access_token:)

    def myshopify_domain
      shop = settings['shop']
      shop.include?('myshopify') ? shop.split('.')[0] : shop
    end

    def shop = "#{myshopify_domain.strip}.myshopify.com"

    def access_token = settings['access_token']
  end
end
