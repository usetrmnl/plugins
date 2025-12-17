module Plugins
  class Withings < Base

    BASE_URL = 'https://wbsapi.withings.net'.freeze

    def locals
      { goals:, current_weight:, metrics:, activity_metrics:, sleep_metrics: }
    end

    def goals
      response = make_request('/v2/user', body: { action: 'getgoals' })
      response['body']['goals'] # ex: {"weight" => {"value" => 70000, "unit" => -3}, "steps" => 10000, "sleep" => 28800}
    end

    def current_weight
      return nil unless metrics.present?

      metrics.last.values.first.round(1)
    end

    def metrics
      return {} if activity_metrics_enabled? # render can show weight chart OR activity (steps/sleep) chart

      @metrics ||= begin
        body = { action: 'getmeas', meastype: 1, startdate: start_date }
        response = make_request('/measure', body:)

        parse_metrics(response)
      end
    end

    def activity_metrics
      return {} unless activity_metrics_enabled?

      @activity_metrics ||= begin
        body = { action: 'getactivity', startdateymd: start_date_ymd, enddateymd: end_date_ymd, data_fields: 'steps,distance,elevation' }
        response = make_request('/v2/measure', body:)

        parse_activity_metrics(response)
      end
    end

    def sleep_metrics
      return {} unless activity_metrics_enabled?

      @sleep_metrics ||= begin
        body = { action: 'getsummary', startdateymd: start_date_ymd, enddateymd: end_date_ymd, data_fields: 'total_timeinbed,total_sleep_time,asleepduration' }
        response = make_request('/v2/sleep', body:)

        parse_sleep_metrics(response)
      end
    end

    # rubocop:disable Style/MultilineBlockChain
    def parse_metrics(data)
      groups = data['body']['measuregrps'].filter { scale_models.include?(it['model']) }

      # type=1 is weight (https://developer.withings.com/api-reference#weight)
      # TODO: support more metrics, e.g. multi series line graph with weight vs fat, muscle
      groups.map do |group|
        measurement = group['measures'].find { it['type'] == 1 }
        value = measurement['value'] / divisor(measurement)
        formatted_value = weight_units == 'kilograms' ? value : (value * 2.20462)

        { group['date'] => formatted_value }
      end.sort_by { it.keys.first } # => [{ 1756494472 => 83.25 }, {1755519350 => 84.1 }]
    end
    # rubocop:enable Style/MultilineBlockChain

    # rubocop:disable Style/MultilineBlockChain
    def parse_activity_metrics(data)
      groups = data['body']['activities'].filter { wearable_models.include?(it['model']) }

      groups.map do |group|
        distance = weight_units == 'kilograms' ? group['distance'] : group['distance'] * 3.28084
        { group['date'] => { steps: group['steps'], distance: distance.round } }
      end.sort_by { it.keys.first } # => [{ '2025-12-07' => {steps: 3489, distance: 2660.78 }, ...]
    end
    # rubocop:enable Style/MultilineBlockChain

    # rubocop:disable Style/MultilineBlockChain
    def parse_sleep_metrics(data)
      groups = data['body']['series'] # doesn't seem to need filtering by model/model_id, which are integers vs strings

      groups.map do |group|
        data = group['data']
        { group['date'] => { total_timeinbed: data['total_timeinbed'], total_sleep_time: data['total_sleep_time'] } }
      end.sort_by { it.keys.first } # => [{ '2025-12-07' => {total_timeinbed: 26220, total_sleep_time: 26100 }, ...]
    end
    # rubocop:enable Style/MultilineBlockChain

    def divisor(measure)
      "1#{'0' * measure['unit'].abs}".to_f
    end

    private

    def scale_models = ['Body Smart', 'Body Scan', 'Body+', 'Body Cardio', 'Body']

    def wearable_models = ['Activite Steel HR']

    def start_date = lookback_period.days.ago.to_i

    def start_date_ymd = lookback_period.days.ago.strftime("%Y-%m-%d")

    def end_date_ymd = Date.today.strftime("%Y-%m-%d")

    def weight_units = settings['weight_units']

    def activity_metrics_enabled? = settings['activity_metrics_enabled'] == 'yes'

    def oauth_client = OauthService::Withings.new(keyname)

    def keyname = plugin_setting.plugin.keyname

    def access_token = settings['withings']['access_token']

    def refresh_token = settings['withings']['refresh_token']

    def make_request(endpoint, body:)
      response = post("#{BASE_URL}#{endpoint}", body: body.to_json, headers: headers)
      raise AccessTokenExpired if response['error']&.include?('The access token provided is invalid')

      JSON.parse(response)
    rescue AccessTokenExpired
      refresh_access_token
      retry
    end

    def refresh_access_token
      token = oauth_client.send('refresh_access_token', refresh_token)
      credentials = plugin_setting.encrypted_settings
      credentials[keyname]['access_token'] = token['access_token']
      credentials[keyname]['refresh_token'] = token['refresh_token'] # this changes 1x per year
      plugin_setting.update(encrypted_settings: credentials)
    end

    def headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Content-Type" => 'application/json'
      }
    end
  end
end
