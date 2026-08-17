module Plugins
  class Close < Base
    def locals
      OauthService::CredentialManager.with_refresh(plugin_setting, max_retries: 3) do |token|
        { opportunities: fetch_opportunity(token) }
      end
    rescue OauthService::CredentialManager::RefreshFailed => e
      fetch_failed!(e.message, opportunities: {})
    end

    class << self
      def redirect_url
        query = {
          response_type: 'code',
          client_id: Rails.application.credentials.plugins[:close][:client_id],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/close/redirect"
        }.to_query
        "https://app.close.com/oauth2/authorize?#{query}"
      end

      def fetch_access_token(code)
        body = {
          grant_type: "authorization_code",
          client_id: Rails.application.credentials.plugins[:close][:client_id],
          client_secret: Rails.application.credentials.plugins[:close][:client_secret],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/close/redirect",
          code: code
        }
        response = HTTParty.post("https://app.close.com/oauth2/token/", body:)
        {
          access_token: response.parsed_response['access_token'],
          refresh_token: response.parsed_response['refresh_token']
        }
      end

      def pipelines(access_token)
        response = HTTParty.get(
          'https://api.close.com/api/v1/pipeline/',
          headers: { "Authorization" => "Bearer #{access_token}" }
        )
        raise OauthService::CredentialManager::TokenExpired if response.parsed_response['error'] == 'Unauthorized'

        (response.parsed_response['data'] || []).flat_map do |pipeline|
          pipeline['statuses'].flatten.map { |status| { "#{pipeline['name']}: #{status['label']}" => status['id'] } }
        end
      end
    end

    private

    def fetch_opportunity(token)
      opportunity = []

      settings['close_pipeline'].each do |status|
        response = HTTParty.get('https://api.close.com/api/v1/opportunity', headers: headers(token), query: query(status))
        raise OauthService::CredentialManager::TokenExpired if response.parsed_response['error'] == 'Unauthorized'

        opportunity += response.parsed_response['data']
      end

      opportunity
        .map { |m| { name: m['lead_name'], type: m['status_type'], value: m['value_formatted'], user: m['user_name'], status: m['status_display_name'], updated: m['date_updated'] } }
        .group_by { |m| m[:status] }
    end

    def query(status)
      {
        date_updated__gt: Date.today - lookback_period.days,
        status_id: status
      }
    end

    def headers(token)
      { "Authorization" => "Bearer #{token}" }
    end
  end
end
