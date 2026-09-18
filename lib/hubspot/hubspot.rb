module Plugins
  class Hubspot < Base
    include ActionView::Helpers::NumberHelper # for number_to_currency

    # HubSpot versions its REST APIs by date, with the version after the API family; numbered /v3/ paths lose support in September 2027
    DEALS_URL = 'https://api.hubapi.com/crm/objects/2026-09/deals'.freeze
    PIPELINES_URL = 'https://api.hubapi.com/crm/pipelines/2026-09/deals'.freeze
    OWNERS_URL = 'https://api.hubapi.com/crm/owners/2026-09'.freeze

    def locals
      OauthService::CredentialManager.with_refresh(plugin_setting, max_retries: 3) do |token|
        { opportunities: opportunities(token) }
      end
    rescue OauthService::CredentialManager::RefreshFailed => e
      fetch_failed!(e.message, opportunities: {})
    end

    class << self
      def pipelines(access_token)
        response = HTTParty.get(PIPELINES_URL, headers: { authorization: "Bearer #{access_token}" })
        raise OauthService::CredentialManager::TokenExpired if response['status'] == 'error' && response['category'] == 'EXPIRED_AUTHENTICATION'

        response['results'].map { |m| { m['label'] => m['id'] } }
      end

      def deal_stages(pipeline_id, access_token)
        return if pipeline_id.blank?

        response = HTTParty.get("#{PIPELINES_URL}/#{pipeline_id}/stages", headers: { authorization: "Bearer #{access_token}" })
        raise OauthService::CredentialManager::TokenExpired if response['status'] == 'error' && response['category'] == 'EXPIRED_AUTHENTICATION'

        response['results'].map { |m| { m['label'] => m['id'] } }
      end
    end

    private

    def opportunities(token)
      url = "#{DEALS_URL}?limit=100&archived=false&properties=hubspot_owner_id,amount,dealname,dealstage"
      next_page = true
      filtered_opportunities = []

      while next_page
        response = instrument_fetch(url) { HTTParty.get(url, headers: { authorization: "Bearer #{token}" }) }
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
      url = "#{OWNERS_URL}/#{owner_id}?idProperty=id&archived=false"
      response = instrument_fetch(url) { HTTParty.get(url, headers: { authorization: "Bearer #{token}" }) }
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
    def deal_stages = settings['hubspot_deal_stages'].map { |m| m.delete(' ').downcase }
  end
end
