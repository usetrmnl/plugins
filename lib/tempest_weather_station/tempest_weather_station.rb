module Plugins
  class TempestWeatherStation < Base

    BASE_URL = 'https://swd.weatherflow.com/swd/rest'.freeze

    def locals
      { temperature:, forecast:, weather_image:, today_weather_image:, tomorrow_weather_image:, conditions:, humidity:, feels_like: }
    end

    class << self
      def redirect_url
        query = {
          response_type: 'code',
          client_id: Rails.application.credentials.plugins[:tempest_weather_station][:client_id],
          redirect_uri: redirect_uri
        }.to_query
        "https://tempestwx.com/authorize.html?#{query}"
      end

      def fetch_access_token(code)
        body = {
          grant_type: "authorization_code",
          client_id: Rails.application.credentials.plugins[:tempest_weather_station][:client_id],
          client_secret: Rails.application.credentials.plugins[:tempest_weather_station][:client_secret],
          redirect_uri: redirect_uri,
          code: code
        }
        response = HTTParty.post("https://swd.weatherflow.com/id/oauth2/token", body:)
        { access_token: response.parsed_response['access_token'] }
      end

      def redirect_uri
        "#{Rails.application.credentials.base_url}/plugin_settings/tempest_weather_station/redirect"
      end

      def devices(credentials)
        resp = HTTParty.get("#{BASE_URL}/stations?token=#{credentials['access_token']}")
        JSON.parse(resp.body)['stations'].map { |s| s['devices'].select { |d| d['device_type'] == 'ST' }.map { |d| { "#{s['name']} (ST #{d['device_id']})" => d['device_id'] } } }.flatten
      end
    end

    private

    # fetching /better_forecast endpoint -> forecast.daily payload begins showing tmrw before day is over
    # this workaround lets us retrieve today's low/high temps in case the forecast is already showing tomorrow
    def today_stats
      @today_stats ||= begin
        today_stats_url = "#{BASE_URL}/stats/station/#{station_id}?api_key=#{access_token}"
        resp = HTTParty.get(today_stats_url)
        data = JSON.parse(resp.body)
        ts = data['stats_day'].filter { |d| d[0] == today_yyyy_mm_dd }.first

        # based on indexing here, but +1 due to the date being prepended
        # https://apidocs.tempestwx.com/reference/get_stats-station-station-id
        {
          air_temp_low: ts[4],
          air_temp_high: ts[5]
        }
      end
    end

    def forecast
      @forecast ||= begin
        url = "#{BASE_URL}/better_forecast?station_id=#{station_id}&token=#{access_token}"
        resp = HTTParty.get(url)
        data = JSON.parse(resp.body)

        right_now = data['current_conditions']
        daily_forecasts = data['forecast']['daily']

        today_forecast_idx = daily_forecasts.index { |d| d['day_num'] == today_day_number }
        tmrw_forecast_idx = daily_forecasts.index { |d| d['day_num'] == tomorrow_day_number }

        today = today_forecast_idx ? daily_forecasts[today_forecast_idx] : today_stats
        tomorrow = daily_forecasts[tmrw_forecast_idx]

        {
          right_now: {
            feels_like: smart_round_in_desired_unit(right_now['feels_like']),
            humidity: right_now['relative_humidity'],
            icon: right_now['icon'],
            temperature: smart_round_in_desired_unit(right_now['air_temperature'])
          },
          today: {
            icon: today['icon'],
            mintemp: smart_round_in_desired_unit(today['air_temp_low']),
            maxtemp: smart_round_in_desired_unit(today['air_temp_high']),
            conditions: today['conditions'],
            uv_index: right_now['uv']
          },
          tomorrow: {
            icon: tomorrow['icon'],
            mintemp: smart_round_in_desired_unit(tomorrow['air_temp_low']),
            maxtemp: smart_round_in_desired_unit(tomorrow['air_temp_high']),
            conditions: tomorrow['conditions'],
            uv_index: data['forecast']['hourly'][12]['uv']&.to_i # unlike right_now['uv'] this val a float; retrieves mid-day (12:00) tmrw, not avail in 'tomorrow' block
          }
        }
      end
    end

    def station_id
      @station_id ||= begin
        resp = HTTParty.get("#{BASE_URL}/stations?token=#{access_token}")
        station_for_device_id = nil
        JSON.parse(resp.body)['stations'].each do |station|
          station['devices'].each do |device|
            station_for_device_id = station['station_id'] if device['device_id'].to_s == device_id
          end
          break if station_for_device_id
        end

        station_for_device_id
      end
    end

    def conditions
      forecast[:today][:conditions]
    end

    # only show graphic for today, not future days
    def weather_image
      forecast[:right_now][:icon]
    end

    def feels_like
      forecast[:right_now][:feels_like]
    end

    def temperature
      forecast[:right_now][:temperature]
    end

    def humidity
      forecast[:right_now][:humidity]
    end

    def today_weather_image
      forecast[:today][:icon]
    end

    def tomorrow_weather_image
      forecast[:tomorrow][:icon]
    end

    def smart_round_in_desired_unit(temp)
      return temp if units == 'c'

      to_fahrenheit(temp).round
    end

    def to_fahrenheit(temp)
      (temp * 9 / 5) + 32
    end

    def units
      settings['units'].downcase == 'metric' ? 'c' : 'f'
    end

    def today_yyyy_mm_dd = Date.today.in_time_zone(user.tz).strftime("%Y-%m-%d")

    def today_day_number = today_yyyy_mm_dd.to_date.mday

    def tomorrow_day_number = (today_yyyy_mm_dd.to_date + 1.days).mday

    # IDEA: allow multiple devices; easy to fetch + grab all data, not easy to layout in view
    def device_id = settings['tempest_weather_station_devices'].to_s

    def access_token = settings['tempest_weather_station']['access_token']
  end
end
