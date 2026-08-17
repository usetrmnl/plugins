module Plugins
  class Enphase < Base
    BASE_URL = 'https://api.enphaseenergy.com/api/v4'.freeze

    NO_SYSTEM_ERROR = 'No Enphase system selected. Please choose a system in settings.'.freeze
    # Enphase answers 401 for both an expired token and a system this account cannot read.
    EXPIRED_SESSION_ERROR = 'Enphase refused this request, so reconnect your account or re-select your system in settings.'.freeze
    # fetch answers nil for a 429, an SSRF block and a network failure alike, so an unsuccessful response has no single cause.
    UNAVAILABLE_ERROR = 'Enphase data unavailable (rate limited or unreachable)'.freeze

    # One fetch serves every device in a household; 110 stays under refresh_every (120) so each scheduled render still refetches.
    CACHE_TTL = 110.minutes
    SYSTEM_LIST_CACHE_TTL = 10.minutes

    REQUIRED_SUMMARY_FIELDS = %w[current_power last_report_at].freeze

    # Enphase answers 422 when the meter isn't installed, the one failure worth inferring anything from.
    class MeterNotInstalled < DataFetchError; end

    class << self
      def systems(access_token)
        return [] if access_token.blank?

        # Keyed by the token, so one account's systems can never be served to another.
        Rails.central_cache_local_fetch("enphase/#{Digest::SHA256.hexdigest(access_token)}/systems",
                                        local_ttl: SYSTEM_LIST_CACHE_TTL, expires_in: SYSTEM_LIST_CACHE_TTL) do
          response = inst.fetch("#{BASE_URL}/systems",
                                headers: { 'Authorization' => "Bearer #{access_token}" },
                                query: { key: api_key })
          raise OauthService::CredentialManager::TokenExpired if response&.code == 401
          raise Helpers::Errors::DataFetchError, UNAVAILABLE_ERROR unless response&.success?

          Array(JSON.parse(response.body)['systems']).map do |system|
            { "#{system['name']} (#{system['system_id']})" => system['system_id'] }
          end
        end
      rescue OauthService::CredentialManager::TokenExpired
        raise
      rescue StandardError => e
        Rails.logger.error "Enphase system list failed: #{e.message}"
        []
      end

      def api_key = Rails.application.credentials.plugins[:enphase][:api_key]
    end

    def locals
      return { errors: NO_SYSTEM_ERROR } if system_id.blank?

      OauthService::CredentialManager.with_refresh(plugin_setting) do |token|
        @access_token = token

        {
          current_power_kw: watts_to_kilowatts(summary['current_power']),
          produced_kwh: watt_hours_to_kilowatt_hours(produced_wh),
          consumed_kwh:,
          imported_kwh:,
          exported_kwh:,
          self_consumed_percent:,
          production_series:,
          last_report_label:,
          battery_power_kw:,
          state_of_charge_percent:
        }
      end
    rescue OauthService::CredentialManager::RefreshFailed
      { errors: EXPIRED_SESSION_ERROR }
    end

    private

    attr_reader :access_token

    def api_key = self.class.api_key

    def system_id = settings['enphase_system'].to_s

    def summary
      @summary ||= authorized_get("systems/#{system_id}/summary").tap do |body|
        raise DataFetchError, UNAVAILABLE_ERROR unless usable_summary?(body)
      end
    end

    def usable_summary?(body) = body.is_a?(Hash) && REQUIRED_SUMMARY_FIELDS.all? { body[it].present? }

    def production_intervals
      @production_intervals ||= Array(authorized_get("systems/#{system_id}/telemetry/production_meter",
                                                     { granularity: 'day' })['intervals'])
    end

    # A site without a consumption current transformer answers with no intervals, or refuses with a 422.
    def consumption_intervals
      @consumption_intervals ||= Array(authorized_get("systems/#{system_id}/telemetry/consumption_meter",
                                                      { granularity: 'day' })['intervals'])
    rescue MeterNotInstalled
      @consumption_intervals = []
    end

    def consumption_metered? = consumption_intervals.any?

    def produced_wh = production_intervals.sum { |interval| interval['wh_del'].to_i }

    def consumed_kwh
      return unless consumption_metered?

      watt_hours_to_kilowatt_hours(consumption_intervals.sum { |interval| interval['enwh'].to_i })
    end

    def imported_kwh
      return unless consumption_metered?

      watt_hours_to_kilowatt_hours(grid_flow[:imported_wh])
    end

    def exported_kwh
      return unless consumption_metered?

      watt_hours_to_kilowatt_hours(grid_flow[:exported_wh])
    end

    # Understates both figures on battery sites, whose consumption excludes battery contribution.
    def grid_flow
      @grid_flow ||= begin
        produced_by_end_at = production_intervals.index_by { |interval| interval['end_at'] }
        consumed_by_end_at = consumption_intervals.index_by { |interval| interval['end_at'] }
        imported_wh = 0
        exported_wh = 0

        (produced_by_end_at.keys | consumed_by_end_at.keys).each do |end_at|
          net_grid_wh = consumed_by_end_at[end_at]&.fetch('enwh', 0).to_i - produced_by_end_at[end_at]&.fetch('wh_del', 0).to_i
          net_grid_wh.positive? ? imported_wh += net_grid_wh : exported_wh -= net_grid_wh
        end

        { imported_wh:, exported_wh: }
      end
    end

    def self_consumed_percent
      return unless consumption_metered?
      return 0 unless produced_wh.positive?

      (((produced_wh - grid_flow[:exported_wh]).to_f / produced_wh) * 100).round.clamp(0, 100)
    end

    # user.tz is nullable and in_time_zone(nil) silently labels the curve in the server's zone.
    def timezone = super.presence || 'UTC'

    # A 15-minute interval's watt-hours are a quarter of its average power, so multiply by four.
    def production_series
      production_intervals.map do |interval|
        [local_time_label(interval['end_at']), (interval['wh_del'].to_i * 4 / 1000.0).round(1)]
      end
    end

    def local_time_label(seconds_since_epoch) = Time.at(seconds_since_epoch).in_time_zone(timezone).strftime('%l:%M %p').strip

    def last_report_label = local_time_label(summary['last_report_at'])

    # Keyed by user, never by the user-supplied system id: two accounts naming one system must not share an entry.
    def authorized_get(path, query = {}, cache_failure_as_nil: false)
      cache_key = "enphase/#{user_id}/#{path}/#{query.to_query}"
      Rails.central_cache_local_delete(cache_key) if force_refresh?

      Rails.central_cache_local_fetch(cache_key, local_ttl: 5.minutes, expires_in: CACHE_TTL) do
        request_json(path, query)
      rescue OauthService::CredentialManager::TokenExpired, DataFetchError
        raise unless cache_failure_as_nil

        nil
      end
    end

    def request_json(path, query)
      response = fetch("#{BASE_URL}/#{path}",
                       headers: { 'Authorization' => "Bearer #{access_token}" },
                       query: query.merge(key: api_key))
      # CredentialManager only refreshes when the block raises TokenExpired.
      raise OauthService::CredentialManager::TokenExpired, 'Unauthorized' if response&.code == 401
      raise MeterNotInstalled, 'Enphase reports no meter behind this endpoint' if response&.code == 422
      raise DataFetchError, UNAVAILABLE_ERROR unless response&.success?

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise DataFetchError, UNAVAILABLE_ERROR
    end

    def battery_capacity_wh = summary['battery_capacity_wh'].to_i

    def battery_present? = battery_capacity_wh.positive?

    def battery_power_kw
      return unless battery_present?

      watts_to_kilowatts(summary['battery_charge_w'].to_i - summary['battery_discharge_w'].to_i)
    end

    # Our plan grants no battery scope, so its 401 is permanent: cache the refusal rather than spend a call per render on it.
    def battery_telemetry
      return unless battery_present?

      @battery_telemetry ||= authorized_get("systems/#{system_id}/telemetry/battery", { granularity: 'day' },
                                            cache_failure_as_nil: true)
    end

    def state_of_charge_percent = battery_telemetry&.dig('last_reported_aggregate_soc').to_s[/\d+/]&.to_i

    def watts_to_kilowatts(watts) = (watts.to_f / 1000).round(1)

    def watt_hours_to_kilowatt_hours(watt_hours) = (watt_hours.to_f / 1000).round(1)
  end
end
