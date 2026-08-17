module Plugins
  class Hubspot < Base

    include ActionView::Helpers::NumberHelper # for number_to_currency

    BASE_URL = 'https://api.hubapi.com/crm/v3/'.freeze
    TOKEN_URL = 'https://api.hubapi.com/oauth/2026-03/token'.freeze

    def locals
      OauthService::CredentialManager.with_refresh(plugin_setting, max_retries: 3) do |token|
        { opportunities: opportunities(token) }
      end
    rescue OauthService::CredentialManager::RefreshFailed => e
      fetch_failed!(e.message, opportunities: {})
    end

    class << self
      def fetch_access_token(code)
        body = {
          code: code,
          client_id: Rails.application.credentials.plugins[:hubspot][:client_id],
          client_secret: Rails.application.credentials.plugins[:hubspot][:client_secret],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/hubspot/redirect",
          grant_type: 'authorization_code'
        }
        response = HTTParty.post(TOKEN_URL, body:)
        {
          access_token: response.parsed_response['access_token'],
          refresh_token: response.parsed_response['refresh_token']
        }
      end

      def redirect_url
        client = Signet::OAuth2::Client.new(client_options)
        client.authorization_uri.to_s
      end

      def pipelines(access_token)
        response = HTTParty.get("#{BASE_URL}pipelines/deals/", headers: { authorization: "Bearer #{access_token}" })
        raise OauthService::CredentialManager::TokenExpired if response['status'] == 'error' && response['category'] == 'EXPIRED_AUTHENTICATION'

        response['results'].map { |m| { m['label'] => m['id'] } }
      end

      def deal_stages(pipeline_id, access_token)
        return if pipeline_id.blank?

        response = HTTParty.get(BASE_URL + "pipelines/deals/#{pipeline_id}/stages", headers: { authorization: "Bearer #{access_token}" })
        raise OauthService::CredentialManager::TokenExpired if response['status'] == 'error' && response['category'] == 'EXPIRED_AUTHENTICATION'

        response['results'].map { |m| { m['label'] => m['id'] } }
      end

      def client_options
        {
          client_id: Rails.application.credentials.plugins[:hubspot][:client_id],
          client_secret: Rails.application.credentials.plugins[:hubspot][:client_secret],
          authorization_uri: 'https://app.hubspot.com/oauth/authorize', # may require change to: '/oauth2/v2/auth'
          token_credential_uri: 'https://app.hubspot.com/oauth/token', # may require change to: '/oauth2/v2/token'
          access_type: 'offline',
          scope: ['crm.pipelines.orders.read', 'crm.objects.deals.read', 'crm.objects.owners.read'],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/hubspot/redirect",
          additional_parameters: {
            prompt: 'consent select_account'
          }
        }
      end
    end

    private

    def opportunities(token)
      url = "#{BASE_URL}objects/deals?limit=100&archived=false&properties=hubspot_owner_id,amount,dealname,dealstage"
      next_page = true
      filtered_opportunities = []

      while next_page
        response = HTTParty.get(url, headers: { authorization: "Bearer #{token}" })
        raise OauthService::CredentialManager::TokenExpired if response['status'] == 'error' && response['category'] == 'EXPIRED_AUTHENTICATION'
        raise DataFetchError, 'HubSpot API unavailable' unless response.success?

        next_page = response.dig('paging', 'next', 'after').present?
        url = response.dig('paging', 'next', 'link') if next_page

        filtered_opportunities << response['results']
                                  .select { |m| deal_stages.include?(m['properties']['dealstage']) }
                                  .map do |m|
          {
            name: m['properties']['dealname'],
            value: number_to_currency(m['properties']['amount']),
            status: deal_stages_hash(token)[m['properties']['dealstage']],
            user: deal_owner(token, m['properties']['hubspot_owner_id'])
          }
        end
      end

      filtered_opportunities.flatten.group_by { |opp| opp[:status] }
    end

    def deal_owner(token, owner_id)
      response = HTTParty.get(BASE_URL + "owners/#{owner_id}?idProperty=id&archived=false'", headers: { authorization: "Bearer #{token}" })
      "#{response['firstName']} #{response['lastName']}"
    end

    def deal_stages_hash(access_token)
      @deal_stages_hash ||= begin
        stages = Plugins::Hubspot.deal_stages(pipeline_id, access_token)
        stages.inject(:merge).invert
      end
    end

    def pipeline_id = settings['hubspot_pipeline_id']

    # should just be 'hubspot_deal_stages' values, but leaving gsub() for backward compatibility
    # until 2026-01-20 we only stored the stage label, then parameterized on our own; can remove after migration
    def deal_stages = settings['hubspot_deal_stages'].map { |m| m.gsub(' ', '').downcase }
  end
end
