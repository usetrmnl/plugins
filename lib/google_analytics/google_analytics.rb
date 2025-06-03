require 'google/apis/analyticsdata_v1beta'

module Plugins
  class GoogleAnalytics < Base

    def locals
      { histogram:, metrics: }
    end

    class << self
      def redirect_url
        client = Signet::OAuth2::Client.new(client_options)
        client.authorization_uri.to_s
      end

      def fetch_access_token(code)
        client = Signet::OAuth2::Client.new(client_options)
        client.code = code
        client.fetch_access_token!
      end

      def client_options
        {
          client_id: Rails.application.credentials.plugins[:google][:client_id],
          client_secret: Rails.application.credentials.plugins[:google][:client_secret],
          authorization_uri: 'https://accounts.google.com/o/oauth2/auth', # may require change to: '/oauth2/v2/auth'
          token_credential_uri: 'https://accounts.google.com/o/oauth2/token', # may require change to: '/oauth2/v2/token'
          access_type: 'offline',
          scope: [Google::Apis::AnalyticsdataV1beta::AUTH_ANALYTICS_READONLY],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/google_analytics/redirect",
          additional_parameters: {
            prompt: 'consent select_account'
          }
        }
      end
    end

    # Helpful hidden gem https://ga-dev-tools.google/query-explorer/

    def metrics
      retry_count = 0
      begin
        date_range = Google::Apis::AnalyticsdataV1beta::DateRange.new(start_date: timestamp_from, end_date: timestamp_to)
        pageviews = Google::Apis::AnalyticsdataV1beta::Metric.new(name: 'screenPageViews')
        sessions = Google::Apis::AnalyticsdataV1beta::Metric.new(name: 'sessions')
        visitors = Google::Apis::AnalyticsdataV1beta::Metric.new(name: 'activeUsers')
        mins_on_page = Google::Apis::AnalyticsdataV1beta::Metric.new(name: 'averageSessionDuration')

        report = Google::Apis::AnalyticsdataV1beta::RunReportRequest.new(
          metrics: [pageviews, sessions, visitors, mins_on_page],
          date_ranges: [date_range]
        )

        service.authorization = client
        response = service.run_property_report(property_id, report)
        return { pageviews: 0, visitors: 0, sessions: 0, mins_on_page: 0 } if response.rows.nil?

        {
          pageviews: response.rows[0].metric_values[0].value.to_i,
          sessions: response.rows[0].metric_values[1].value.to_i,
          visitors: response.rows[0].metric_values[2].value.to_i,
          mins_on_page: (response.rows[0].metric_values[3].value.to_f / 60).round(2)
        }
      rescue Google::Apis::AuthorizationError
        refresh!
        retry_count += 1
        if retry_count <= 1 # Retry just once, otherwise retry next day.
          sleep 2
          retry
        else
          plugin_settings.refresh_in_24hr
          {}
        end
      rescue Signet::AuthorizationError, Google::Apis::ClientError => e
        handle_erroring_state(e.message)
        {}
      end
    end

    def histogram
      retry_count = 0
      begin
        date_range = Google::Apis::AnalyticsdataV1beta::DateRange.new(start_date: timestamp_from, end_date: timestamp_to)
        metric = Google::Apis::AnalyticsdataV1beta::Metric.new(name: 'screenPageViews')
        dimension = Google::Apis::AnalyticsdataV1beta::Dimension.new(name: 'date')

        report = Google::Apis::AnalyticsdataV1beta::RunReportRequest.new(dimensions: [dimension],
                                                                         metrics: [metric],
                                                                         date_ranges: [date_range],
                                                                         filters_expression: {})
        service.authorization = client
        response = service.run_property_report(property_id, report)
        return [] if response.rows.nil?

        response.rows
                .map { |m| { date: Date.parse(m.dimension_values[0].value), pageviews: m.metric_values[0].value } }
                .sort! { |a, b| a[:date] <=> b[:date] }
                .each { |m| m[:date] = m[:date].strftime('%Y-%m-%d') }
      rescue Google::Apis::AuthorizationError
        refresh!
        retry_count += 1
        if retry_count <= 1 # Retry just once, otherwise retry next day.
          sleep 2
          retry
        else
          handle_erroring_state('Google::Apis::AuthorizationError')
          {}
        end
      rescue Signet::AuthorizationError, Google::Apis::ClientError => e
        handle_erroring_state(e.message)
        {}
      end
    end

    def service
      @service ||= Google::Apis::AnalyticsdataV1beta::AnalyticsDataService.new
    end

    def client
      credentials = settings['google_analytics']
      oauth_client = Signet::OAuth2::Client.new(Plugins::GoogleAnalytics.client_options)
      oauth_client.update!(credentials)
      oauth_client
    end

    def refresh!
      response = client.refresh!
      credentials = plugin_settings.encrypted_settings
      credentials['google_analytics']['access_token'] = response['access_token']
      plugin_settings.update(encrypted_settings: credentials)
      self.settings = plugin_settings.settings.merge(plugin_settings.encrypted_settings)
    rescue Signet::AuthorizationError
      handle_erroring_state('Signet::AuthorizationError')
    end

    # user suggestion to prevent the graph always 'dropping off' on current day
    # leveraging case() to ensure no funny business / non permitted string injection
    def timestamp_to
      case settings["lookback_until"]
      when '', nil
        Date.today.to_s
      when 'yesterday', 'today'
        Date.send(settings["lookback_until"]).to_s
      end
    end

    def timestamp_from = lookback_period.days.ago.beginning_of_day.strftime('%Y-%m-%d')

    def property_id = "properties/#{settings['property_id']}"
  end
end
