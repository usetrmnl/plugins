module Plugins
  class GoogleCalendar < Base
    def locals
      { events:, event_layout:, include_description:, include_event_time:, first_day:, scroll_time:, time_format:, today_in_tz: }
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
          scope: [
            Google::Apis::CalendarV3::AUTH_CALENDAR_READONLY,
            Google::Apis::CalendarV3::AUTH_CALENDAR_EVENTS_READONLY
          ],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/google_calendar/redirect",
          additional_parameters: {
            prompt: 'consent select_account'
          }
        }
      end

      def list_calendar(credentials)
        client = Signet::OAuth2::Client.new(Plugins::GoogleCalendar.client_options)
        client.update!(credentials["google_calendar"])
        service = Google::Apis::CalendarV3::CalendarService.new
        begin
          service.authorization = client
          service.list_calendar_lists.items.map { |m| { m.summary => m.id } }
        rescue Google::Apis::AuthorizationError
          client.refresh!
          retry
        rescue Google::Apis::ClientError # PERMISSION_DENIED: Request had insufficient authentication scopes
          # in this case, it's possible the user only has 1 calendar, so our 'AUTH_CALENDAR_READONLY' scope is ignored
          [{ 'primary' => 'primary' }]
        end
      end
    end

    def events
      @prepare_events ||= prepare_events
    end

    def prepare_events
      retry_count = 0

      begin
        service = Google::Apis::CalendarV3::CalendarService.new
        service.authorization = client

        all_events = []
        calendars.each do |calendar_email|
          # TODO: investigate, maybe Google Cal does support ordering by start Time? mixed reports:
          # https://github.com/googleapis/google-api-ruby-client/blob/main/samples/cli/lib/samples/calendar.rb#L65
          events = service.list_events(calendar_email, single_events: true, time_min: now_in_tz.beginning_of_day.iso8601, time_max: time_max).items
          events.each do |event|
            all_events << prepare_event(event, calendar_email)
          end
        rescue Google::Apis::ClientError => e
          puts "Plugins::GoogleCalendar-> Google::Apis::ClientError: #{calendar_email} #{plugin_settings.id} #{e.message}"
        rescue Google::Apis::ServerError
          sleep 1
          retry
        end

        # de-duplicates events if every param (except calname) matches -- helpful for family calendars where multiple entries otherwise exist for same event
        unique_events = all_events.uniq { |evt| evt.values_at(:summary, :description, :status, :date_time, :day, :all_day, :start_full, :end_full, :start, :end) }

        unique_events.compact.sort_by { |e| e[:date_time] }.group_by { |e| e[:day] } # G Cal doesn't allow native sorting
      rescue Google::Apis::AuthorizationError
        refresh!
        retry_count += 1
        if retry_count <= 1 # Retry just once, otherwise retry next day.
          sleep 1
          retry
        else
          plugin_settings.refresh_in_24hr
          {}
        end
      rescue Signet::AuthorizationError
        handle_erroring_state('Signet::AuthorizationError')
        {}
      end
    end

    def prepare_event(event, calendar_email)
      # private events that don't share full details with connected calendar have a nil summary
      # setting this here so that users may 'ignore' events with a Busy status
      event.summary ||= 'Busy'
      return if event_should_be_ignored?(event, calendar_email)

      start_date = event.start.date_time || event.start.date

      # some params below are only needed for 1 or more event_layout options but not all
      # however all must be included as user may set event_layout==week, then create a mashup with event_layout==default
      layout_params = {
        start_full: event.start.date_time&.in_time_zone(time_zone) || event.start.date,
        end_full: event.end.date_time&.in_time_zone(time_zone) || event.end.date,
        start: event.start.date_time&.in_time_zone(time_zone)&.strftime(formatted_time) || event.start.date,
        end: event.end.date_time&.in_time_zone(time_zone)&.strftime(formatted_time) || event.end.date
      }

      {
        summary: event.summary,
        description: sanitize(event.description) || '',
        status: event.status,
        date_time: start_date,
        day: start_date.in_time_zone(time_zone).strftime('%B %d'),
        all_day: (event.start.date_time || event.end.date_time).nil?,
        calname: calname(event)
      }.merge(layout_params)
    end

    def calendars
      # 'flatten()' ensures back/forward compatibility btwn single vs multi-select dropdown
      [settings['calendar']].flatten.uniq
    end

    # event object doesn't have a calendar/parent type attr like ICS event.parent
    # rather than pass calendar_email into prepare_event(), simply look up which attendee is 'me' (self)
    def calname(event)
      event&.attendees&.find(&:self)&.email
    end

    def client
      credentials = settings['google_calendar']
      oauth_client = Signet::OAuth2::Client.new(Plugins::GoogleCalendar.client_options)
      oauth_client.update!(credentials)
      oauth_client
    end

    def time_zone = user.tz || 'America/New_York'

    def formatted_time
      return "%-I:%M %p" if time_format == 'am/pm'

      "%R"
    end

    def time_format
      settings['time_format'] || 'am/pm'
    end

    def event_should_be_ignored?(event, calendar_email)
      includes_ignored_phrases?(event) || ignore_based_on_acceptance?(event, calendar_email) || ignore_based_on_time?(event) || ignore_based_on_status?(event)
    end

    # not possible to filter for *only* events accepted by user
    # also, generated events don't have attendees (B-day, recurring / self-assigned)
    def ignore_based_on_acceptance?(event, calendar_email)
      attendees = event.attendees || [Struct.new(:response_status, :email).new('accepted', calendar_email)]
      !attendees.find { |a| a.email == calendar_email }&.response_status == 'accepted'
    end

    # consider changing this to use 'start' vs 'end'
    def ignore_based_on_time?(event)
      end_date = event.end.date_time || event.end.date
      end_date.in_time_zone(time_zone) < cutoff_time
    end

    def ignore_based_on_status?(event)
      return false if event.status&.downcase == 'confirmed' # always include confirmed events

      # include non-confirmed events if user prefers to see them (received requests for both options)
      # if this branch is reached, event.status == [nil, 'rejected'] etc
      settings['event_status_filter'] == 'confirmed_only'
    end

    def includes_ignored_phrases?(event)
      summary_includes = ignored_phrases.any? { |phrase| event.summary.include?(phrase) }
      description_includes = ignored_phrases.any? { |phrase| (event.description || '').include?(phrase) }

      summary_includes || description_includes
    end

    def ignored_phrases
      settings['ignore_phrases']&.gsub("\n", "")&.gsub("\r", "")&.split(',')&.map(&:squish) || []
    end

    def event_layout
      settings['event_layout']
    end

    # some users prefer to maintain 'state' and see already-passed events
    # default is to ignore events already completed on this same day
    def cutoff_time
      settings['include_past_events'] == 'yes' ? now_in_tz.beginning_of_day : now_in_tz
    end

    def time_max
      days_ahead = case event_layout
                   when 'month'
                     30 # don't simply get remainder of month; FullCalendar 'previews' next month near the end
                   else
                     7
                   end

      (now_in_tz + days_ahead.days).iso8601
    end

    def now_in_tz
      DateTime.now.in_time_zone(time_zone)
    end

    # required to ensure locals data has a 'diff' at least 1x per day
    # given week/month view 'highlight' current day
    # without this local, previous day will be highlighted if events dont change
    def today_in_tz
      now_in_tz.to_date.to_s
    end

    def include_description
      return true unless settings['include_description'] # backward compatible default value

      settings['include_description'] == 'yes'
    end

    def include_event_time
      return false unless settings['include_event_time'] # backward compatible default value

      settings['include_event_time'] == 'yes'
    end

    def first_day
      Date.strptime(settings['first_day'], '%a').wday
    end

    # ability to hard-code each day's first time slot in event_layout=week mode
    # by default we lookup the earliest event within the period, but some users
    # prefer to sacrifice morning visibility to see more throughout the day
    def scroll_time
      return settings['scroll_time'] if settings['scroll_time'].present?

      events.values.flatten.reject { |e| e[:all_day] }.map { |e| e[:start_full].to_time.strftime("%H:00:00") }.min || '08:00:00'
    end

    def refresh!
      response = client.refresh!
      credentials = plugin_settings.encrypted_settings
      credentials['google_calendar']['access_token'] = response['access_token']
      plugin_settings.update(encrypted_settings: credentials)
      self.settings = plugin_settings.settings.merge(plugin_settings.encrypted_settings)
    rescue Signet::AuthorizationError
      handle_erroring_state('Signet::AuthorizationError')
    end
  end
end
