module Plugins
  class TempestWeatherStation < Base

    BASE_URL = 'https://swd.weatherflow.com/swd/rest'.freeze

    def locals
      { temperature:, forecast:, weather_image:, today_weather_image:, tomorrow_weather_image:, today_conditions:, right_now_conditions:, humidity:, feels_like:, refreshed_at: }
    end

    class << self
      def for_weather_instance(plugin_setting)
        self.new(plugin_setting).locals
      end

      def devices(credentials)
        resp = HTTParty.get("#{BASE_URL}/stations?token=#{credentials['access_token']}")
        JSON.parse(resp.body)['stations'].map { |s| s['devices'].select { |d| d['device_type'] == 'ST' }.map { |d| { "#{s['name']} (ST #{d['device_id']})" => d['device_id'] } } }.flatten
      end
    end

    private

    def today_stats
      # TODO: get access to /stations endpoint with lat/lon bounding box to resolve evening high/low fetch
      @today_stats ||= if plugin.keyname == 'weather'
                         ts = daily_forecasts[0]
                         {
                           air_temp_low: ts['air_temp_low'],
                           air_temp_high: ts['air_temp_high']
                         }
                       else
                         # fetching /better_forecast endpoint -> forecast.daily payload begins showing tmrw before day is over
                         # this workaround lets us retrieve today's low/high temps in case the forecast is already showing tomorrow

                         today_stats_url = "#{BASE_URL}/stats/station/#{station_id}?api_key=#{access_token}"
                         resp = fetch(today_stats_url)
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

    # rubocop:disable Metrics/AbcSize
    def forecast
      @forecast ||= begin
        today_forecast_idx = daily_forecasts.index { |d| Time.at(d['day_start_local']).in_time_zone(timezone).to_date.to_s == today_yyyy_mm_dd }
        tmrw_forecast_idx = daily_forecasts.index { |d| Time.at(d['day_start_local']).in_time_zone(timezone).to_date.to_s == tomorrow_yyyy_mm_dd }

        today = today_forecast_idx ? daily_forecasts[today_forecast_idx] : today_stats
        tomorrow = daily_forecasts[tmrw_forecast_idx]

        {
          right_now: {
            feels_like: smart_round_in_desired_unit(right_now['feels_like']),
            humidity: right_now['relative_humidity'],
            icon: right_now['icon'],
            temperature: smart_round_in_desired_unit(right_now['air_temperature']),
            sunrise: today['sunrise'] ? Time.at(today['sunrise']).in_time_zone(user.tz).strftime("%H:%M") : '',
            sunset: today['sunset'] ? Time.at(today['sunset']).in_time_zone(user.tz).strftime("%H:%M") : '',
            sunrise_unix: today['sunrise'] ? Time.at(today['sunrise']).to_i : '',
            sunset_unix: today['sunset'] ? Time.at(today['sunset']).to_i : '',
            wind: { direction_cardinal: right_now['wind_direction_cardinal'], gust: right_now['wind_gust'], units: units_wind },
            conditions: right_now['conditions']
          },
          today: {
            icon: today['icon'],
            mintemp: smart_round_in_desired_unit(today['air_temp_low']),
            maxtemp: smart_round_in_desired_unit(today['air_temp_high']),
            day_override: forecast_day_override('today'),
            conditions: today['conditions'],
            uv_index: max_uv_for('today'), # previously: right_now['uv'],
            precip: { icon: today['precip_icon'], probability: today['precip_probability'], amount: right_now['precip_accum_local_day'], units: units_precip }
          },
          tomorrow: {
            icon: tomorrow['icon'],
            mintemp: smart_round_in_desired_unit(tomorrow['air_temp_low']),
            maxtemp: smart_round_in_desired_unit(tomorrow['air_temp_high']),
            day_override: forecast_day_override('tomorrow'),
            conditions: tomorrow['conditions'],
            uv_index: max_uv_for('tomorrow'),
            precip: { icon: tomorrow['precip_icon'], probability: tomorrow['precip_probability'] }
          }
        }
      end
    end
    # rubocop:enable Metrics/AbcSize

    def forecast_data
      @forecast_data ||= begin
        resp = HTTParty.get(forecast_url)
        JSON.parse(resp.body)
      end
    end

    def forecast_url
      @forecast_url ||= if plugin.keyname == 'weather'
                          "#{BASE_URL}/better_forecast?units_precip=#{units_precip}&#{weather_station_selection}&api_key=#{Rails.application.credentials.plugins.weather.tempest_api_key}"
                        else
                          "#{BASE_URL}/better_forecast?station_id=#{station_id}&units_wind=#{units_wind}&units_precip=#{units_precip}&token=#{access_token}"
                        end
    end

    def weather_station_selection
      if settings['tempest_station_id'].present?
        "station_id=#{settings['tempest_station_id']}"
      else
        "#{lat_lon_query}&snap_to_nearest_owned_station=true"
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

    def forecast_day_override(day)
      return nil unless forecast_headings == 'absolute_date'

      case day
      when 'today'
        today.strftime("%b %d")
      when 'tomorrow'
        (today + 1.day).strftime("%b %d")
      end
    end

    def lat_lon_query
      str = if settings['lat_lon'].include?(',')
              settings['lat_lon'].split(',')
            elsif settings['lat_lon'].include?('/')
              settings['lat_lon'].split('/')
            else
              settings['lat_lon'].split
            end

      lat, lon = str.map(&:squish)
      "lat=#{lat}&lon=#{lon}"
    end

    # override Tempest defaults with native Weather icons on a case by case basis based on user feedback
    def icon_selector(icon)
      native_icon_base_uri = "#{Rails.application.credentials.plugin_asset_url}/images/plugins/weather"

      case icon
      when 'clear-day'
        "#{native_icon_base_uri}/wi-day-sunny.svg"
      when 'clear-night'
        "#{native_icon_base_uri}/wi-night-clear.svg"
      else
        "https://tempestwx.com/images/Updated/#{icon}.svg"
      end
    end

    # only show graphic for today, not future days
    def weather_image
      icon = forecast[:right_now][:icon]
      icon_selector(icon)
    end

    def today_weather_image
      icon = forecast[:today][:icon]
      icon_selector(icon)
    end

    def tomorrow_weather_image
      icon = forecast[:tomorrow][:icon]
      icon_selector(icon)
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

    def refreshed_at
      I18n.l(plugin_setting.previous_refresh_at.in_time_zone(user.tz), format: :short, locale: user.locale).split[-1]
    end

    def max_uv_for(period)
      max_uv = case period
               when 'today' # returns a smaller sample throughout the date, so UV will be 0 in evening; TODO: fetch past data
                 hourly_forecasts.map { |hf| hf['uv'] if Time.at(hf['time']).between?(beginning_of_today, end_of_today) }.compact.max
               when 'tomorrow' # should always return 24 hours of UV data
                 hourly_forecasts.map { |hf| hf['uv'] if Time.at(hf['time']).between?(beginning_of_tomorrow, end_of_tomorrow) }.compact.max
               end

      # => 5.0 should be 5, 5.4 should be 5.4
      max_uv.to_i == max_uv ? max_uv.to_i : max_uv.round(1)
    end

    def smart_round_in_desired_unit(temp)
      return temp if units == 'c'

      to_fahrenheit(temp).round
    end

    def to_fahrenheit(temp)
      (temp * 9 / 5) + 32
    end

    def right_now = forecast_data['current_conditions']

    def hourly_forecasts = forecast_data['forecast']['hourly']

    def daily_forecasts = forecast_data['forecast']['daily']

    def today_conditions = forecast[:today][:conditions]

    def right_now_conditions = forecast[:right_now][:conditions]

    def forecast_headings = settings['forecast_headings']

    def units = settings['units'].downcase == 'metric' ? 'c' : 'f'

    def units_wind = settings['units_wind']

    def units_precip = settings['units_precip']

    def today = user.datetime_now

    def today_yyyy_mm_dd = today.strftime("%Y-%m-%d")

    def tomorrow_yyyy_mm_dd = (today + 1.day).strftime("%Y-%m-%d")

    def beginning_of_today = Time.now.beginning_of_day

    def end_of_today = Time.now.end_of_day

    def beginning_of_tomorrow = DateTime.tomorrow.beginning_of_day

    def end_of_tomorrow = DateTime.tomorrow.end_of_day

    # IDEA: allow multiple devices; easy to fetch + grab all data, not easy to lay out however
    def device_id = settings['tempest_weather_station_devices'].to_s

    def access_token = settings['tempest_weather_station']['access_token']
  end
end
