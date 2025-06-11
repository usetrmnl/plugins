module Plugins
  class GoogleCalendar < Base
    include Calendar::Helper

    def locals
      { events:, event_layout:, include_description:, include_event_time:, first_day:, scroll_time:, scroll_time_end:, time_format:, today_in_tz: beginning_of_day, zoom_mode: }
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
          events = service.list_events(calendar_email, single_events: true, time_min: time_min.iso8601, time_max: time_max).items
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
        unique_events = all_events.compact.uniq { |evt| evt.values_at(:summary, :description, :status, :date_time, :all_day, :start_full, :end_full, :start, :end) }

        unique_events.sort_by { |e| e[:date_time] }
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

      # some params below are only needed for 1 or more event_layout options but not all
      # however all must be included as user may set event_layout==week, then create a mashup with event_layout==default

      {
        summary: event.summary,
        description: sanitize(event.description) || '',
        status: event.status,
        date_time: start_date(event),
        all_day: all_day?(event),
        calname: calname(event),
        start_full: safe_start_time(event),
        end_full: safe_end_time(event),
        start: safe_start_time(event, in_strftime: true),
        end: safe_end_time(event, in_strftime: true)
      }
    end

    def calendars
      # 'flatten()' ensures back/forward compatibility btwn single vs multi-select dropdown
      [settings['calendar']].flatten.uniq
    end

    # event object doesn't have a calendar/parent type attr like ICS event.parent
    # rather than pass calendar_email into prepare_event(), simply look up which attendee is 'me' (self)
    def calname(event)
      # event&.creator&.email == event creator, but this could be many different people; not useful for grouping
      event&.attendees&.find(&:self)&.email
    end

    def all_day?(event)
      (event.start.date_time || event.end.date_time).nil?
    end

    def safe_start_time(event, in_strftime: false)
      st = event.start.date_time&.in_time_zone(time_zone)

      if in_strftime
        st&.strftime(formatted_time) || event.start.date
      else
        st || event.start.date
      end
    end

    def safe_end_time(event, in_strftime: false)
      et_raw = event.end.date_time&.in_time_zone(time_zone)

      if in_strftime
        et_raw&.strftime(formatted_time) || event.end.date
      else
        # all-day events (+ multi-day events) "end" at 00:00 on the following day,
        # but should appear in calendar as ending at 11:59 on the previous day
        # this is a known quirk of G Cal + Microsoft schemas; see core/pulls#1183 for details
        # however, multi-day events need their original end date of +1 day for FullCalendar parser
        et_raw || event.end.date
      end
    end

    def client
      credentials = settings['google_calendar']
      oauth_client = Signet::OAuth2::Client.new(Plugins::GoogleCalendar.client_options)
      oauth_client.update!(credentials)
      oauth_client
    end

    def time_zone = user.tz || 'America/New_York'

    def start_date(event)
      event.start.date_time || event.start.date
    end

    def event_should_be_ignored?(event, calendar_email)
      includes_ignored_phrases?(event) ||
        ignore_based_on_acceptance?(event, calendar_email) ||
        ignore_based_on_time?(event) ||
        ignore_based_on_status?(event)
    end

    # not possible to filter for *only* events accepted by user
    # also, generated events don't have attendees (B-day, recurring / self-assigned)
    def ignore_based_on_acceptance?(event, calendar_email)
      attendees = event.attendees || [Struct.new(:response_status, :email).new('accepted', calendar_email)]
      !attendees.find { |a| a.email == calendar_email }&.response_status == 'accepted'
    end

    def ignore_based_on_time?(event)
      end_date = safe_end_time(event)
      end_date.in_time_zone(time_zone) < cutoff_time
    end

    def includes_ignored_phrases?(event)
      summary_includes = ignored_phrases.any? { |phrase| event.summary.include?(phrase) }
      description_includes = ignored_phrases.any? { |phrase| (event.description || '').include?(phrase) }

      summary_is = ignored_phrases_exact_match.any? { |phrase| event.summary&.strip == phrase }
      description_is = ignored_phrases_exact_match.any? { |phrase| event.description&.strip == phrase }

      summary_includes || description_includes || summary_is || description_is
    end

    def ignored_phrases_exact_match = line_separated_string_to_array(settings['ignore_phrases_exact_match'] || '')

    # Google API response already includes multi-day all_day events even if queried for today.
    # Example if event is between dates 01-05 and if we query for events between 03-10 (week), it'd still return the multi-day all_day event between 01-05
    # So unlike ics calendar type it's not necessary to go back X days to get multi-day all day events.
    def time_min
      days_behind = case [event_layout, include_past_event?]
                    when ['month', true], ['rolling_month', true]
                      30
                    else # ['month', false], ['week', true], ['week', false], ['default', true], ['default', false], ['today_only', true], ['today_only', false]
                      0
                    end

      (beginning_of_day - days_behind.days)
    end

    def time_max
      days_ahead = case event_layout
                   when 'month', 'rolling_month'
                     30 # don't simply get remainder of month; FullCalendar 'previews' next month near the end
                   else
                     7
                   end

      (beginning_of_day + days_ahead.days).iso8601
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
