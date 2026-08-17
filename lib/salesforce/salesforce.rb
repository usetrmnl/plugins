module Plugins
  class Salesforce < Base

    # https://developer.salesforce.com/docs/atlas.en-us.api_rest.meta/api_rest/dome_versions.htm
    BASE_URL = 'https://trmnl-dev-ed.develop.my.salesforce.com/services/data/v61.0'.freeze

    def locals
      OauthService::CredentialManager.with_refresh(plugin_setting, max_retries: 3) do |token|
        { opportunities: fetch_opportunities(token) }
      end
    rescue OauthService::CredentialManager::RefreshFailed
      fetch_failed!("Token refresh failed", opportunities: {})
    end

    private

    def fetch_opportunities(token)
      opportunities = []

      settings['salesforce_opportunity_views'].each do |view|
        response = HTTParty.get("#{BASE_URL}/sobjects/Opportunity/listviews/#{view}/results", headers: Plugins::Salesforce.headers(token))
        raise OauthService::CredentialManager::TokenExpired if response.code == 401

        data = JSON.parse(response.body)

        # clean up Salesforce native formatting
        opportunities += data['records'].map do |opp|
          attrs = opp['columns']
          attrs = attrs.map { |attr| { attr['fieldNameOrPath'] => attr['value'] } }
          attrs << { 'type' => data['label'] }
          attrs.reduce(:merge)
        end
      end

      opportunities
        .map { |o| { name: o['Name'], value: o['Amount'], user: o['Owner.Alias'], status: o['StageName'], type: o['type'], updated: o['LastModifiedDate'] } }
        .group_by { |o| o[:type] }
    end

    class << self
      # docs: https://trailhead.salesforce.com/content/learn/projects/build-a-connected-app-for-api-integration/implement-the-oauth-20-web-server-authentication-flow
      # app: https://trmnl-dev-ed.develop.my.salesforce.com/app/mgmt/forceconnectedapps/forceAppDetail.apexp?applicationId=06Pak000001c5vl&applicationId=06Pak000001c5vl&id=0Ciak0000004Wvl
      def redirect_url
        query = {
          response_type: 'code',
          client_id: Rails.application.credentials.plugins[:salesforce][:consumer_key],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/salesforce/redirect"
        }.to_query
        "https://trmnl-dev-ed.develop.my.salesforce.com/services/oauth2/authorize?#{query}"
      end

      def fetch_access_token(code)
        body = {
          grant_type: "authorization_code",
          client_id: Rails.application.credentials.plugins[:salesforce][:consumer_key],
          client_secret: Rails.application.credentials.plugins[:salesforce][:consumer_secret],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/salesforce/redirect",
          code: code
        }
        response = HTTParty.post("https://trmnl-dev-ed.develop.my.salesforce.com/services/oauth2/token", body:)
        {
          access_token: response.parsed_response['access_token'],
          refresh_token: response.parsed_response['refresh_token']
        }
      end

      # TODO: observe resp['nextRecordsUrl'] and aggregate all results
      def opportunity_views(access_token)
        resp = HTTParty.get("#{BASE_URL}/sobjects/Opportunity/listviews", headers: Plugins::Salesforce.headers(access_token))
        raise OauthService::CredentialManager::TokenExpired if resp.code == 401

        JSON.parse(resp.body)['listviews'].map { |l| { l['label'] => l['id'] } }
      end

      def headers(token)
        {
          'content-type' => 'application/json',
          'authorization' => "Bearer #{token}"
        }
      end
    end
  end
end
