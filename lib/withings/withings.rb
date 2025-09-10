module Plugins
  class Withings < Base

    BASE_URL = 'https://wbsapi.withings.net'.freeze

    def locals
      { goals:, current_weight:, metrics: }
    end

    def goals
      response = make_request('/v2/user', body: { action: 'getgoals' })
      response['body']['goals'] # ex: {"weight" => {"value" => 70000, "unit" => -3}, "steps" => 10000, "sleep" => 28800}
    end

    def current_weight
      metrics.last.values.first.round(1)
    end

    def metrics
      @metrics ||= begin
        body = { action: 'getmeas', meastype: 1, startdate: start_date }
        response = make_request('/measure', body:)

        parse_and_format_metrics(response)
      end
    end

    def parse_and_format_metrics(data)
      metrics = parse_metrics(data)
      format_metrics(metrics)
    end

    def parse_metrics(data)
      groups = data['body']['measuregrps'].filter { device_models.include?(it['model']) }

      unit = groups.first['measures'].first['unit']
      divisor = "1#{'0' * unit.abs}".to_f

      # type=1 is weight (https://developer.withings.com/api-reference#weight)
      # TODO: support more metrics, e.g. multi series line graph with weight vs fat, muscle
      groups.map { |g| { g['date'] => g['measures'].find { it['type'] == 1 }['value'] / divisor } }.sort_by { it.keys.first } # => [{ 1756494472 => 83.25 }, {1755519350 => 84.1 }]
    end

    def format_metrics(metrics)
      return metrics if weight_units == 'kilograms'

      metrics.map { |m| { m.keys.first => m.values.first * 2.20462 } }
    end

    private

    def device_models = ['Body Smart', 'Body Scan', 'Body+', 'Body Cardio']

    def start_date = lookback_period.days.ago.to_i

    def weight_units = settings['weight_units']

    def oauth_client = OauthService::Withings.new(keyname)

    def keyname = plugin_settings.plugin.keyname

    def access_token = settings['withings']['access_token']

    def refresh_token = settings['withings']['refresh_token']

    def make_request(endpoint, body:)
      response = post("#{BASE_URL}#{endpoint}", body: body.to_json, headers: headers)
      raise AccessTokenExpired if response['error']&.include?('The access token provided is invalid')

      JSON.parse(response)
    rescue AccessTokenExpired
      token = oauth_client.send('refresh_access_token', refresh_token)
      credentials = plugin_settings.encrypted_settings
      credentials[keyname]['access_token'] = token['access_token']
      credentials[keyname]['refresh_token'] = token['refresh_token'] # this changes 1x per year
      plugin_settings.update(encrypted_settings: credentials)
      retry
    end

    def headers
      {
        "Authorization" => "Bearer #{access_token}",
        "Content-Type" => 'application/json'
      }
    end
  end
end
