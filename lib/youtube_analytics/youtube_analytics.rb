module Plugins
  class YoutubeAnalytics < Base
    def locals
      { metrics: }
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
          scope: [Google::Apis::YoutubeAnalyticsV2::AUTH_YT_ANALYTICS_READONLY],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/youtube_analytics/redirect",
          additional_parameters: {
            prompt: 'consent select_account'
          }
        }
      end
    end

    private

    def metrics = fetch_analytics

    def fetch_analytics
      retry_count = 0
      begin
        service = Google::Apis::YoutubeAnalyticsV2::YouTubeAnalyticsService.new
        service.authorization = client

        report = service.query_report(
          ids: "channel==MINE",
          start_date: start_date,
          end_date: end_date,
          metrics: "views,estimatedMinutesWatched,averageViewDuration,averageViewPercentage,subscribersGained,likes,dislikes,comments,shares",
          dimensions: "day",
          sort: "day"
        )

        process_report(report)
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
      rescue Google::Apis::ClientError => e
        handle_erroring_state(e.message)
      end
    end

    def process_report(report)
      kpis = {
        views: 0,
        minutes_watched: 0,
        average_view_duration: 0,
        average_view_percentage: 0,
        subscribers_gained: 0,
        likes: 0,
        dislikes: 0,
        comments: 0,
        shares: 0
      }

      report.rows.each do |metrics|
        kpis[:views] += metrics[1].round(2)
        kpis[:minutes_watched] += metrics[2].round(2)
        kpis[:average_view_duration] += metrics[3].round(2)
        kpis[:average_view_percentage] += metrics[4].round(2)
        kpis[:subscribers_gained] += metrics[5].round(2)
        kpis[:likes] += metrics[6].round(2)
        kpis[:dislikes] += metrics[7].round(2)
        kpis[:comments] += metrics[8].round(2)
        kpis[:shares] += metrics[9].round(2)
      end

      kpis[:average_view_duration] = (kpis[:average_view_duration] / settings['duration'].to_i).round(2)
      kpis[:average_view_percentage] = (kpis[:average_view_percentage] / settings['duration'].to_i).to_i
      kpis
    end

    def start_date = (Date.today - settings['duration'].to_i.days).to_s

    def end_date = Date.today.to_s

    def client
      credentials = settings['youtube_analytics']
      oauth_client = Signet::OAuth2::Client.new(Plugins::YoutubeAnalytics.client_options)
      oauth_client.update!(credentials)
      oauth_client
    end

    def refresh!
      response = client.refresh!
      credentials = plugin_settings.encrypted_settings
      credentials['youtube_analytics']['access_token'] = response['access_token']
      plugin_settings.update(encrypted_settings: credentials)
      self.settings = plugin_settings.settings.merge(plugin_settings.encrypted_settings)
    rescue Signet::AuthorizationError
      handle_erroring_state('Signet::AuthorizationError')
    end
  end
end
