module Plugins
  class GoogleCalendar < Base
    include Calendar::Helper

    def locals
      OauthService::CredentialManager.with_refresh(plugin_setting) do |token|
        @current_access_token = token
        super.merge(calendar_names:)
      end
    rescue OauthService::CredentialManager::RefreshFailed
      fetch_failed!("Token refresh failed")
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

      def list_calendar(access_token)
        service = Google::Apis::CalendarV3::CalendarService.new
        service.authorization = GoogleOauthClient.build(self, access_token)
        service.list_calendar_lists.items.map { |m| { m.summary => m.id } }
      rescue Google::Apis::AuthorizationError
        raise OauthService::CredentialManager::TokenExpired
      rescue Google::Apis::ClientError # PERMISSION_DENIED: Request had insufficient authentication scopes
        # in this case, it's possible the user only has 1 calendar, so our 'AUTH_CALENDAR_READONLY' scope is ignored
        [{ 'primary' => 'primary' }]
      end
    end

    def events
      @prepare_events ||= prepare_events
    end

    def prepare_events
      all_events = []

      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = GoogleOauthClient.build(self.class, access_token)

      calendars.each do |calendar_email|
        # TODO: investigate, maybe Google Cal does support ordering by start Time? mixed reports:
        # https://github.com/googleapis/google-api-ruby-client/blob/main/samples/cli/lib/samples/calendar.rb#L65
        events = events_for_calendar(service, calendar_email)
        events.each do |event|
          all_events << prepare_event(event, calendar_email)
        end
      rescue Google::Apis::ClientError => e
        # Raw message carries the user's email — log only the leading reason keyword (e.g. notFound)
        Rails.logger.warn "Plugins::GoogleCalendar-> Google::Apis::ClientError: plugin_setting_id=#{plugin_setting.id} status=#{e.status_code} reason=#{e.message[/\A\w+/]}"
      rescue Google::Apis::ServerError
        sleep 1
        retry
      end

      # de-duplicates events if every param (except calname) matches -- helpful for family calendars where multiple entries otherwise exist for same event
      all_events
        .compact
        .uniq { |evt| evt.values_at(:summary, :description, :status, :date_time, :all_day, :start_full, :end_full, :start, :end) }
        .sort_by { |e| e[:date_time] }
    rescue Google::Apis::AuthorizationError
      raise OauthService::CredentialManager::TokenExpired
    rescue Signet::AuthorizationError => e
      handle_erroring_state(e.message)
      []
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
        calname: calendar_email,
        background_color: event_color_definitions[event.color_id].presence || calendar_colors[calendar_email],
        location: event.location,
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

    def calendar_names
      @calendar_names ||= fetch_calendar_names
    end

    def calendar_colors
      @calendar_colors ||= fetch_calendar_colors
    end

    def event_color_definitions
      @event_color_definitions ||= fetch_event_color_definitions
    end

    private

    def access_token = @current_access_token || settings.dig('google_calendar', 'access_token')

    def fetch_calendar_names
      return {} if calendars.empty?

      calendar_list = self.class.list_calendar(access_token)
      calendar_mapping = {}

      calendar_list.each do |cal_hash|
        cal_hash.each do |name, id|
          calendar_mapping[id] = name if calendars.include?(id)
        end
      end

      calendar_mapping
    rescue OauthService::CredentialManager::TokenExpired
      raise
    rescue StandardError => e
      logger.error "Plugins::GoogleCalendar.fetch_calendar_names -> #{e.message}"
      {}
    end

    def fetch_calendar_colors
      return {} if calendars.empty?

      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = GoogleOauthClient.build(self.class, access_token)

      entries = instrument_fetch(service.root_url) { service.list_calendar_lists.items }
      entries.each_with_object({}) do |entry, mapping|
        mapping[entry.id] = entry.background_color if calendars.include?(entry.id)
      end
    rescue Google::Apis::AuthorizationError
      raise OauthService::CredentialManager::TokenExpired
    rescue Signet::AuthorizationError => e
      handle_erroring_state(e.message)
      {}
    rescue StandardError => e
      logger.error "Plugins::GoogleCalendar.fetch_calendar_colors -> #{e.message}"
      {}
    end

    def fetch_event_color_definitions
      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = GoogleOauthClient.build(self.class, access_token)
      instrument_fetch(service.root_url) { service.get_color }.event.transform_values(&:background)
    rescue Google::Apis::AuthorizationError
      raise OauthService::CredentialManager::TokenExpired
    rescue Signet::AuthorizationError => e
      handle_erroring_state(e.message)
      {}
    rescue StandardError => e
      logger.error "Plugins::GoogleCalendar.fetch_event_color_definitions -> #{e.message}"
      {}
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
      attendees.find { |a| a.email == calendar_email }&.response_status == 'declined'
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

    # Google API response already includes multi-day all_day events even if queried for today.
    # Example if event is between dates 01-05 and if we query for events between 03-10 (week), it'd still return the multi-day all_day event between 01-05
    # So unlike ics calendar type it's not necessary to go back X days to get multi-day all day events.
    def time_min
      days_behind = case [event_layout, include_past_event?]
                    when ['month', true], ['rolling_month', true]
                      30
                    when ['week', true], ['rolling_week', true], ['work_week', true]
                      7
                    else # all other layouts without past events enabled
                      0
                    end

      (beginning_of_day - days_behind.days)
    end

    def time_max(extend: false)
      days_ahead = case event_layout
                   when 'month', 'rolling_month'
                     42 # FullCalendar month grid can show up to 6 weeks (42 days)
                   when 'schedule'
                     14
                   when 'today_only'
                     1
                   else
                     7
                   end

      # helps prevent blank screen if calendar is mostly empty
      days_ahead += 7 if extend && event_layout == 'schedule'
      (beginning_of_day + days_ahead.days).iso8601
    end

    def events_for_calendar(service, calendar_email)
      evts = fetch_events(service, calendar_email, time_max)
      return evts if evts.present? || event_layout == 'today_only'

      # IDEA: refactor time_max(extend) to a while() that adds a few more days until events present, with a max cutoff
      fetch_events(service, calendar_email, time_max(extend: true))
    end

    def fetch_events(service, calendar_email, ends_at)
      instrument_fetch(service.root_url) do
        service.list_events(calendar_email, single_events: true, time_min: time_min.iso8601, time_max: ends_at).items
      end
    end
  end
end
