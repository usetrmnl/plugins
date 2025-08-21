module Plugins
  class Parcel < Base

    # maps Parcel status codes to I18n keys "renders.parcel.status.{status_key}"
    # (fall back to 'renders.parcel.status.unknown')
    STATUS_KEYS = {
      0 => 'delivered',
      1 => 'frozen',
      2 => 'in_transit',
      3 => 'expecting_pickup',
      4 => 'out_for_delivery',
      5 => 'not_found',
      6 => 'failed_delivery_attempt',
      7 => 'delivery_exception',
      8 => 'information_received'
    }.freeze

    def locals
      result = fetch_deliveries
      skip_display = skip_if_empty? && result[:error].nil? && result[:deliveries].empty?

      {
        deliveries: result[:deliveries].map { delivery_item(it) },
        error: result[:error],
        filter_mode: filter_mode.humanize,
        skip_display:,
        style:
      }
    end

    private

    def delivery_item(delivery)
      {
        title: delivery['description'],
        status_key: status_key(delivery['status_code']),
        latest: latest_event(delivery['events']),
        delivery_by: delivery_by(delivery),
        days: delivery_days(delivery)
      }
    end

    def style = settings['style'] || 'detailed'

    def api_key = settings['api_key']

    def filter_mode = settings['filter_mode']

    def skip_if_empty? = settings['empty_state'] == 'skip'

    def headers = { 'api-key' => api_key, 'user-agent' => 'TRMNL Server' }

    def query = { 'filter_mode' => filter_mode }

    def url = 'https://api.parcel.app/external/deliveries/'

    def cache_key = "parcel_#{api_key}"

    def fetch_deliveries
      # API docs: https://parcelapp.net/help/api.html
      # "The rate limit is 20 requests per hour."
      Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        response = HTTParty.get(url, headers:, query:)

        if response.success?
          data = JSON.parse(response.body) # content-type is wrong (text/html), so we need to explicitly parse the body
          if data['success']
            { deliveries: data['deliveries'], error: nil }
          elsif data['error_message'].present?
            { deliveries: [], error: data['error_message'] }
          else
            { deliveries: [], error: t('renders.parcel.errors.api') }
          end
        else
          { deliveries: [], error: t('renders.parcel.errors.http', code: response.code) }
        end
      end
    rescue StandardError
      { deliveries: [], error: t('renders.parcel.errors.internal') }
    end

    def status_key(status_code)
      STATUS_KEYS.fetch(status_code, 'unknown')
    end

    def user_today
      user.datetime_now.to_date
    end

    def delivery_days(delivery)
      return unless delivery['date_expected'].present?

      date_expected = DateTime.parse(delivery['date_expected']).to_date

      days = (date_expected - user_today).to_i
      days >= 0 ? days : nil
    rescue Date::Error
      nil
    end

    def latest_event(events)
      return nil if events.blank?

      events.first['event']
    end

    def delivery_by(delivery)
      delivery_days = delivery_days(delivery)
      return unless delivery_days

      date_expected = DateTime.parse(delivery['date_expected']).to_date
      if delivery_days >= 7
        l(date_expected, format: :short) # far in the future
      elsif delivery_days == 1
        t('renders.parcel.tomorrow') # tomorrow
      elsif delivery_days.zero?
        t('renders.parcel.today') # today
      else
        l(date_expected, format: '%A') # day of week
      end
    rescue Date::Error
      nil
    end
  end
end
