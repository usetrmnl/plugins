module Plugins
  # A door sign for one Mazevo room: in use or available now, then the rest of today's bookings.
  class Mazevo < Base
    include Calendar::Ics

    EVENTS_PATH = '/api/PublicEvent/getevents'.freeze
    ROOMS_PATH = '/api/PublicConfiguration/Rooms'.freeze
    API_KEY_REJECTED_MESSAGE = 'Mazevo rejected the API key'.freeze
    ROOM_MISSING_MESSAGE = 'Choose a room in the plugin settings'.freeze
    LOCATION_BUILDING_SEPARATOR = ' - '.freeze
    ROOM_NOT_IN_FEED_MESSAGE = 'Room not found in this feed'.freeze
    UNEXPECTED_ANSWER_MESSAGE = 'Mazevo did not answer with a list of bookings'.freeze

    # The key lacks the Building and Rooms Calls permission group.
    class RoomsForbidden < StandardError; end

    class << self
      def api_endpoint(api_url, path) = "#{api_url.to_s.strip.chomp('/')}#{path}"

      def api_headers(api_key) = { 'X-API-Key' => api_key.to_s, 'Content-Type' => 'application/json' }

      def feed_locations(bodies)
        bodies.flat_map { Icalendar::Calendar.parse(it).flat_map(&:events) }
              .filter_map { it.location.to_s.strip.presence }
              .uniq.sort
      end

      def room_label(location) = location.to_s.split(LOCATION_BUILDING_SEPARATOR, 2).last.to_s.strip

      # Room dropdown options, [{ label => value }]: room ids from the API, LOCATION strings from a feed.
      def list_rooms(data_provider:, api_url:, api_key:, ics_url:)
        data_provider == 'ics_link' ? feed_rooms(ics_url) : api_rooms(api_url, api_key)
      end

      def api_rooms(api_url, api_key)
        response = OutboundUrlGuard.post(api_endpoint(api_url, ROOMS_PATH), headers: api_headers(api_key),
                                                                            body: { buildingId: 0 }.to_json, timeout: 10)
        return [] if OutboundUrlGuard.refused?(response)
        raise RoomsForbidden if response.code == 401
        return [] unless response.success?

        Array(response.parsed_response).grep(Hash)
                                       .reject { it['disabled'] }
                                       .sort_by { [it['buildingDescription'].to_s, it['description'].to_s] }
                                       .map { { "#{it['buildingDescription']} · #{it['description'].to_s.strip}" => it['roomId'] } }
      rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
        []
      end

      def feed_rooms(ics_url)
        response = Calendar::SafeUrlFetcher.get(ics_url, headers: {}, timeout: 30)
        return [] unless response.success?

        feed_locations([response.body]).map { { room_label(it) => it } }
      rescue Calendar::SafeUrlFetcher::BlockedURLError, SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
        # The fetcher raises for a blocked/SSRF host or a network failure; OutboundUrlGuard.post answers a sentinel instead.
        []
      end
    end

    def events
      @events ||= api_provider? ? api_events : feed_events
    end

    # The sign shows one day, so both sources fetch just today.
    def time_min = beginning_of_day

    def time_max = refresh_time.end_of_day

    def locals
      {
        room_name:, current_event:, upcoming_events:, finished_events:,
        todays_date: I18n.l(refresh_time.to_date, format: '%A, %B %-d', locale:),
        updated_at: refresh_time.strftime(formatted_time),
        footer_note: settings['footer_note'].presence
      }
    end

    private

    def refresh_time = @refresh_time ||= now_in_tz

    def room_id = settings['room_id'].presence || settings['mazevo_room'].presence

    def api_provider? = settings['data_provider'] != 'ics_link'

    def room_location = settings['mazevo_room'].to_s.strip

    def feed_events
      return room_missing if room_location.blank?

      matched = prepare_events.select { it[:location].to_s.strip == room_location }
      handle_erroring_state("#{ROOM_NOT_IN_FEED_MESSAGE}: #{room_location}") if matched.empty? && !feed_has_room?
      matched
    end

    # The whole feed, not today's window: a room that is merely free today is not a missing room.
    def feed_has_room?
      self.class.feed_locations(calendar_bodies).include?(room_location)
    rescue Icalendar::Parser::ParseError, NoMethodError
      true
    end

    def api_events
      return room_missing unless room_id.to_s.match?(/\A\d+\z/)

      response = post(self.class.api_endpoint(settings['api_url'], EVENTS_PATH),
                      headers: self.class.api_headers(settings['api_key']), body: events_request_body.to_json)
      # Not response.nil?: HTTParty::Response delegates nil? to an empty body and answers true.
      return api_failed(fetch_failure_reason) if response.is_a?(NilClass)
      return api_failed(API_KEY_REJECTED_MESSAGE) if response.code == 401
      return api_failed("the host replied #{response.code}") unless response.success?

      bookings = response.parsed_response
      return api_failed(UNEXPECTED_ANSWER_MESSAGE) unless bookings.is_a?(Array)

      bookings.grep(Hash).filter_map { prepare_booking(it) }.select { it[:end_full] > time_min }.sort_by { it[:start_full] }
    end

    # Whether GetEvents filters by start or by overlap is undocumented, so the window starts a day
    # early to catch either one; api_events drops what ended before today so both answers are right.
    def events_request_body
      {
        start: (time_min - 1.day).iso8601, end: time_max.iso8601, roomIds: [room_id.to_i], buildingIds: [],
        eventTypeIds: [], statusIds: [], explodeComboRooms: true, includeRelatedRooms: true
      }
    end

    def prepare_booking(booking)
      return if booking['booked'] == false

      starts_at = booking_time(booking['dateTimeStart'])
      ends_at = booking_time(booking['dateTimeEnd'])
      return unless starts_at && ends_at

      hidden = booking['bookingPrivate'] == true
      {
        summary: (booking['eventName'] unless hidden), private: hidden,
        description: (booking['organizationName'].presence unless hidden),
        location: booking['roomDescription'].to_s.strip, status: booking['statusDescription'].to_s,
        date_time: starts_at, all_day: false, start_full: starts_at, end_full: ends_at,
        start: starts_at.strftime(formatted_time), end: ends_at.strftime(formatted_time)
      }
    end

    # Mazevo stamps each time with its own offset; the zone only picks the wall clock shown.
    def booking_time(value)
      Time.find_zone!(time_zone).iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def api_failed(message)
      handle_erroring_state(message) if message
      []
    end

    def room_missing
      handle_erroring_state(ROOM_MISSING_MESSAGE)
      []
    end

    def room_name = settings['display_name'].presence || picked_room_name.presence || plugin_setting.name

    def picked_room_name = api_provider? ? events.first&.dig(:location) : self.class.room_label(room_location)

    def current_event = events.find { it[:start_full] <= refresh_time && refresh_time < it[:end_full] }

    # end_full, not start_full: a booking overlapping the current one but starting later must still
    # show. Identity, not Array#-: two combo-room rows can serialize identically.
    def upcoming_events = events.select { it[:end_full] > refresh_time }.reject { it.equal?(current_event) }

    def finished_events = include_past_event? ? events.select { it[:end_full] <= refresh_time } : []
  end
end
