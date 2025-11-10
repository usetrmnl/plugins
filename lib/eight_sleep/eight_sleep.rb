module Plugins
  class EightSleep < Base

    AUTH_URL = 'https://auth-api.8slp.net/v1/tokens'.freeze
    BASE_URL = 'https://app-api.8slp.net/v1'.freeze

    def locals
      { metrics: }
    end

    private

    def metrics
      create_access_token

      resp = fetch(metrics_url, headers:)
      JSON.parse(resp.body)['periods'][0]
    end

    def metrics_url
      fields = 'sfs,sqs,srs,sleep,light,rem,rem_percent,deep,deep_percent,hr,hrv,br,bedtime,wakeup,ttfa,ttgu,snore,snore_heavy,snore_percent,snore_heavy_percent'
      "#{BASE_URL}/users/#{user_id}/metrics/aggregate?to=#{today}&tz=#{tz}&metrics=#{fields}&periods=week"
    end

    # spoofs mobile app login
    def create_access_token
      resp = post(AUTH_URL, body: auth_body, headers: auth_headers)
      update_credentials(resp)
    end

    def update_credentials(resp, refreshing: false)
      data = JSON.parse(resp.body) # => { 'access_token', 'refresh_token', 'expires_in', 'userId', etc }

      # refreshing tokens does not respond with userId
      data = data.merge({ 'userId' => user_id }) if refreshing

      credentials = plugin_setting.encrypted_settings
      credentials['eight_sleep'] = data
      plugin_setting.update(encrypted_settings: credentials)
    end

    # anything cool we can do with this endpoint data?
    def me
      fetch('https://client-api.8slp.net/v1/users/me', headers:)
    end

    # https://github.com/lukas-clarke/eight_sleep/blob/101bbf88cdce8aeb7b449a29a1761cfd6004b65a/custom_components/eight_sleep/pyEight/constants.py#L30
    def auth_body
      {
        client_id: '0894c7f33bb94800a03f1f4df13a4f38',
        client_secret: 'f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76',
        grant_type: 'password',
        username:,
        password:
      }.to_json
    end

    def auth_headers
      {
        'content-type': "application/json",
        'user-agent': "Android App",
        'accept-encoding': "gzip",
        accept: "application/json"
      }
    end

    def headers
      {
        'content-type': 'application/json',
        connection: 'keep-alive',
        'user-agent': 'Home Assistant/2024.10.3-14058 (Android 14; SM-S911U1)', # based on: https://github.com/home-assistant/frontend/issues/19374#issuecomment-2506470285
        'accept-encoding': 'gzip',
        accept: 'application/json',
        host: 'app-api.8slp.net',
        authorization: "Bearer #{access_token}"
      }
    end

    def access_token = plugin_setting.encrypted_settings.dig('eight_sleep', 'access_token')

    def user_id = plugin_setting.encrypted_settings.dig('eight_sleep', 'userId')

    def password = settings['password']

    def username = settings['email']

    def tz = ActiveSupport::TimeZone::MAPPING[user.tz] || 'America/New_York'

    def today = user.datetime_now.to_date
  end
end
