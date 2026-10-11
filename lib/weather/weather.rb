module Plugins
  class Weather < Base
    include WeatherAPI::CodesAndConditions

    def locals
      if data_provider == 'tempest'
        tempest_locals = Plugins::TempestWeatherStation.for_weather_instance(plugin_setting)
        { data_provider: }.merge(tempest_locals)
      else
        return { errors: data['error']['message'] } if data.dig('error', 'message').present?

        { data_provider:, temperature:, forecast:, weather_image:, today_weather_image:, tomorrow_weather_image:, conditions:, humidity:, feels_like:, utc_offset:, time_format: }
      end
    end

    private

    def temperature = data.dig('current', "temp_#{unit_suffix}")&.to_f

    def forecast
      today = forecast_day(0)
      tomorrow = forecast_day(1)
      raise DataFetchError, 'Weather forecast unavailable' if today.blank? || tomorrow.blank?

      {
        today: forecast_summary(today, forecast_day_override('today')),
        tomorrow: forecast_summary(tomorrow, forecast_day_override('tomorrow'))
      }
    end

    def forecast_summary(day, day_override)
      {
        mintemp: smart_round(day.dig('day', "mintemp_#{unit_suffix}")),
        maxtemp: smart_round(day.dig('day', "maxtemp_#{unit_suffix}")),
        day_override:,
        conditions: condition_text(day.dig('day', 'condition'), force_daytime: true),
        uv_index: uv(day.dig('day', 'uv'))
      }
    end

    def forecast_day(index) = data.dig('forecast', 'forecastday', index)

    def condition_text(condition, force_daytime: false)
      return if condition.blank?

      localized_condition = localized_condition_for(condition['code'])
      return condition['text'] if localized_condition.nil?

      day? || force_daytime ? localized_condition[:day] : localized_condition[:night]
    end

    # show whole numbers in Fahrenheit
    def smart_round(temp)
      return if temp.nil?

      unit_suffix == 'c' ? temp.to_f : temp.to_f.round
    end

    def weather_image
      condition = weather_condition_for(weather_code)

      day? ? condition[:icon_day] : condition[:icon_night]
    end

    def today_weather_image = forecast_weather_image(0)

    def tomorrow_weather_image = forecast_weather_image(1)

    def forecast_weather_image(index)
      weather_condition_for(forecast_day(index)&.dig('day', 'condition', 'code'))[:icon_day]
    end

    def localized_condition_for(code)
      t('renders.weather.weatherapi.conditions', locale:).find { |c| c[:code] == code }
    end

    def weather_condition_for(code) = WEATHER_CONDITIONS.find { |c| c[:code] == code } || UNKNOWN_CONDITION

    def conditions = condition_text(data.dig('current', 'condition'))

    def uv(index)
      return if index.nil?

      # Look up the leaf, not the whole hash: I18n treats a hash of nil values as found and never falls back.
      level = case index
              when ..2 then :low
              when ..5 then :moderate
              when ..7 then :high
              when ..10 then :very_high
              else :extreme
              end

      "#{t("renders.weather.weatherapi.uv.#{level}", locale:).titleize} (#{index.round(1)})"
    end

    def forecast_day_override(day)
      return nil unless forecast_headings == 'absolute_date'

      today = user.datetime_now

      case day
      when 'today'
        today.strftime("%b %d")
      when 'tomorrow'
        (today + 1.day).strftime("%b %d")
      end
    end

    # TODO: make this better so we choose an appropriate image
    # seems to currently show 'day' image for too long
    def day? = data.dig('current', 'is_day') == 1

    def weather_code = data.dig('current', 'condition', 'code')

    def debug = data['location'].except!('localtime', 'localtime_epoch')

    def data
      @data ||= begin
        response = fetch(url)
        payload = response.try(:parsed_response) || response
        raise DataFetchError, 'Weather API unavailable' unless payload.is_a?(Hash)

        payload
      end
    end

    def url = "https://api.weatherapi.com/v1/forecast.json?key=#{api_key}&q=#{location}&aqi=yes&days=#{forecast_days}"

    # IDEA: allow user to modify
    def forecast_days = 2

    def forecast_headings = settings['forecast_headings']

    def api_key = Rails.application.credentials.plugins[:weather][:api_key]

    def location = CGI.escape(settings['location'] || '')

    def unit_suffix = settings['units'].to_s.downcase == 'metric' ? 'c' : 'f'

    def humidity = data.dig('current', 'humidity')

    def feels_like = data.dig('current', "feelslike_#{unit_suffix}")&.to_f

    # assume Fahrenheit users prefer 12 hour clock
    def time_format = unit_suffix == 'f' ? '%l:%M %p' : '%H:%M'

    def utc_offset = user.datetime_now.utc_offset

    def data_provider
      settings['data_provider'] ||= 'weatherapi'
    end
  end
end
