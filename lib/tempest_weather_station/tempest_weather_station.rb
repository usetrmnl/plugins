module Plugins
  class TempestWeatherStation < Base

    BASE_URL = 'https://swd.weatherflow.com/swd/rest'.freeze
    def locals
      { temperature:, forecast:, weather_image:, today_weather_image:, tomorrow_weather_image:, today_conditions:, right_now_conditions:, humidity:, feels_like:, utc_offset:, time_format:, meta: }
    end

    class << self
      def for_weather_instance(plugin_setting)
        self.new(plugin_setting).locals
      end

      def devices(credentials)
        resp = HTTParty.get("#{BASE_URL}/stations?token=#{credentials['access_token']}")
        stations = JSON.parse(resp.body)['stations']
        return [] if stations.blank?

        stations.map { |s| Array(s['devices']).select { |d| d['device_type'] == 'ST' }.map { |d| { "#{s['name']} (ST #{d['device_id']})" => d['device_id'] } } }.flatten
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
                         ts = stats_day_row_for_today
                         # based on indexing here, but +1 due to the date being prepended
                         # https://apidocs.tempestwx.com/reference/get_stats-station-station-id
                         {
                           air_temp_low: ts&.[](4),
                           air_temp_high: ts&.[](5)
                         }
                       end
    end

    def stats_day_row_for_today
      # Fetches and caches the stats row for today from the /stats/station endpoint
      # This is used for both temperature and wind data
      @stats_day_row_for_today ||= begin
        today_stats_url = "#{BASE_URL}/stats/station/#{station_id}?api_key=#{access_token}"
        data = parsed_body(fetch(today_stats_url))
        Array(data&.dig('stats_day')).find { |d| d[0] == today_yyyy_mm_dd }
      end
    end

    # rubocop:disable-next Metrics/AbcSize
    def forecast
      @forecast ||= begin
        today_forecast_idx = daily_forecasts.index { |d| Time.at(d['day_start_local']).in_time_zone(timezone).to_date.to_s == today_yyyy_mm_dd }
        tmrw_forecast_idx = daily_forecasts.index { |d| Time.at(d['day_start_local']).in_time_zone(timezone).to_date.to_s == tomorrow_yyyy_mm_dd }

        # fetching /better_forecast endpoint -> forecast.daily payload begins showing tmrw before day is over
        # This caches the today forecast, so if it's not in the response, we can still grab it.
        if today_forecast_idx
          today = daily_forecasts[today_forecast_idx]
          forecast_cache.write_today(today)
        else
          today = forecast_cache.read_today || today_stats

          # If we have cached forecast data, merge in actual temps from today_stats
          # This gives us: icons/sunrise/sunset from cache + actual high/low temps that occurred today
          # (instead of predicted temps from when the forecast was cached earlier in the day)
          if today.is_a?(Hash) && today != today_stats && today_stats
            today = today.merge(
              'air_temp_low' => today_stats[:air_temp_low],
              'air_temp_high' => today_stats[:air_temp_high]
            )
          end
        end

        tomorrow = tmrw_forecast_idx && daily_forecasts[tmrw_forecast_idx]
        raise DataFetchError, 'Tempest forecast unavailable' if today.blank? || tomorrow.blank?

        {
          right_now: {
            feels_like: display_temperature(right_now['feels_like']),
            humidity: right_now['relative_humidity'],
            icon: right_now['icon'],
            temperature: display_temperature(right_now['air_temperature']),
            sunrise: today['sunrise'] ? Time.at(today['sunrise']).in_time_zone(user.tz).strftime(time_format) : '',
            sunset: today['sunset'] ? Time.at(today['sunset']).in_time_zone(user.tz).strftime(time_format) : '',
            sunrise_unix: today['sunrise'] ? Time.at(today['sunrise']).to_i : '',
            sunset_unix: today['sunset'] ? Time.at(today['sunset']).to_i : '',
            wind: {
              direction_cardinal: right_now['wind_direction_cardinal'],
              gust: right_now['wind_gust'],
              units: wind_unit_label,
              max: wind_min_max_for_today[:max]
            },
            conditions: translate_tempest_condition(right_now['conditions'])
          },
          today: {
            icon: today['icon'],
            mintemp: smart_round_in_desired_unit(today['air_temp_low']),
            maxtemp: smart_round_in_desired_unit(today['air_temp_high']),
            day_override: forecast_day_override('today'),
            conditions: translate_tempest_condition(today['conditions']),
            uv_index: max_uv_for('today'), # previously: right_now['uv'],
            precip: { icon: today['precip_icon'], probability: today['precip_probability'], amount: right_now['precip_accum_local_day'], units: units_precip }
          },
          tomorrow: {
            icon: tomorrow['icon'],
            mintemp: smart_round_in_desired_unit(tomorrow['air_temp_low']),
            maxtemp: smart_round_in_desired_unit(tomorrow['air_temp_high']),
            day_override: forecast_day_override('tomorrow'),
            conditions: translate_tempest_condition(tomorrow['conditions']),
            uv_index: max_uv_for('tomorrow'),
            precip: { icon: tomorrow['precip_icon'], probability: tomorrow['precip_probability'] }
          }
        }
      end
    end

    def forecast_data
      @forecast_data ||= fetched_forecast || forecast_cache.read ||
                         raise(DataFetchError, 'Tempest forecast unavailable')
    end

    def fetched_forecast
      parsed_body(fetch(forecast_url))&.tap { forecast_cache.write(it) }
    end

    def forecast_url
      @forecast_url ||= if plugin.keyname == 'weather'
                          "#{BASE_URL}/better_forecast?units_precip=#{units_precip}&#{station.selection_query}&api_key=#{Rails.application.credentials.plugins.weather.tempest_api_key}"
                        else
                          "#{BASE_URL}/better_forecast?station_id=#{station_id}&units_wind=#{units_wind}&units_precip=#{units_precip}&token=#{access_token}"
                        end
    end

    def station = @station ||= Station.new(plugin_setting, settings)

    def station_id = station.id

    def forecast_day_override(day)
      return nil unless forecast_headings == 'absolute_date'

      case day
      when 'today'
        today.strftime("%b %d")
      when 'tomorrow'
        (today + 1.day).strftime("%b %d")
      end
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

    def utc_offset = user.datetime_now.utc_offset

    def max_uv_for(period)
      max_uv = case period
               when 'today' # returns a smaller sample throughout the date, so UV will be 0 in evening; TODO: fetch past data
                 hourly_forecasts.filter_map { |hf| hf['uv'] if Time.zone.at(hf['time']).between?(beginning_of_today, end_of_today) }.max
               when 'tomorrow' # should always return 24 hours of UV data
                 hourly_forecasts.filter_map { |hf| hf['uv'] if Time.zone.at(hf['time']).between?(beginning_of_tomorrow, end_of_tomorrow) }.max
               end

      # => 5.0 should be 5, 5.4 should be 5.4
      return if max_uv.nil?

      max_uv.to_i == max_uv ? max_uv.to_i : max_uv.round(1)
    end

    def wind_min_max_for_today
      # Use actual observation data from the stats endpoint when available (tempest_weather_station plugin)
      # Fall back to forecast data for the weather plugin (which may not have station access)
      if plugin.keyname != 'weather' && today_wind_stats[:max].present?
        today_wind_stats
      else
        # Fallback to forecast data (note: this only shows forecasted values for remaining hours)
        wind_values = hourly_forecasts.filter_map { |hf| hf['wind_avg'] if Time.zone.at(hf['time']).between?(beginning_of_today, end_of_today) }

        if wind_values.any?
          { max: wind_values.max.round }
        else
          { max: 0 }
        end
      end
    end

    def today_wind_stats
      @today_wind_stats ||= begin
        ts = stats_day_row_for_today

        if ts
          # Based on API docs (with +1 offset for date prepended):
          # API index 19 (wind_gust) -> ts[20]
          # Stats endpoint returns m/s, convert to user's preferred unit
          wind_gust_mps = ts[20] || 0

          { max: convert_wind_from_mps(wind_gust_mps).round }
        else
          { max: nil }
        end
      end
    end

    def convert_wind_from_mps(mps) = WindSpeed.from_mps(mps, units_wind)

    def smart_round_in_desired_unit(temp)
      return if temp.nil?
      return temp if units == 'c'

      to_fahrenheit(temp).round
    end

    def display_temperature(temp) = smart_round_in_desired_unit(temp)&.round

    def to_fahrenheit(temp)
      return if temp.nil?

      (temp * 9 / 5) + 32
    end

    def right_now = forecast_data['current_conditions']

    # raw readings (pressure, lightning, dew point...) for Remix and data mode; not in the default templates
    def meta = forecast_data.slice('current_conditions', 'units')

    def hourly_forecasts = forecast_data.dig('forecast', 'hourly') || []

    def daily_forecasts
      daily = forecast_data.dig('forecast', 'daily')
      raise DataFetchError, 'Tempest forecast unavailable' if daily.blank?

      daily
    end

    def today_conditions = forecast[:today][:conditions]

    def right_now_conditions = forecast[:right_now][:conditions]

    def forecast_headings = settings['forecast_headings']

    def units = settings['units'].to_s.downcase == 'metric' ? 'c' : 'f'

    # If using Fahrenheit, use 12-hour clock. Otherwise, use 24-hour clock
    def time_format = units == 'f' ? "%l:%M %p" : "%H:%M"

    def units_wind = settings['units_wind']

    def wind_unit_label = WindSpeed.label(units_wind)

    def units_precip = settings['units_precip']

    def today = user.datetime_now

    def today_yyyy_mm_dd = today.strftime("%Y-%m-%d")

    def tomorrow_yyyy_mm_dd = (today + 1.day).strftime("%Y-%m-%d")

    def forecast_cache
      @forecast_cache ||= ForecastCache.new(plugin_setting_id: id, user_id: user.id, today: today_yyyy_mm_dd)
    end

    def beginning_of_today = Time.zone.now.beginning_of_day

    def end_of_today = Time.zone.now.end_of_day

    def beginning_of_tomorrow = DateTime.tomorrow.beginning_of_day

    def end_of_tomorrow = DateTime.tomorrow.end_of_day

    def access_token = settings['tempest_weather_station']['access_token']

    def translate_tempest_condition(condition_string)
      return nil if condition_string.blank?

      key = condition_string.to_s.downcase.gsub(/\s+/, '_').gsub(/[^a-z_]/, '')
      t("renders.weather.tempest.conditions.#{key}", locale:, default: condition_string)
    end
  end
end
