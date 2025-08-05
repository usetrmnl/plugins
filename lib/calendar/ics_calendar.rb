# all ICS calendars look like this; they compile a hash of ~6 values and collections
module Plugins
  class OutlookCalendar < Base
    include Calendar::Ics

    def locals
      { events:, event_layout:, include_description:, include_event_time:, first_day:, scroll_time:, scroll_time_end:, time_format:, today_in_tz: beginning_of_day, zoom_mode: }
    end
  end
end

# module below is included in all ICS calendars (ex: Apple, Outlook, Fastmail, Nextcloud, etc)
require_relative 'ics_rrule_helper'
require_relative 'ics_event_helper'

module Calendar
  module Ics
    include Helper
    include IcsRruleHelper
    include IcsEventHelper
    include TimezoneHelper

    def events
      @prepare_events ||= prepare_events
    end

    def prepare_events
      unique_events.sort_by { |e| e[:date_time] }
    rescue Plugins::Helpers::Errors::InvalidURL
      handle_erroring_state("ics_url is invalid")
      {}
    rescue ArgumentError => e
      handle_erroring_state(e.message) if e.message.include?("DNS name: nil")
      {}
    rescue Icalendar::Parser::ParseError => e
      handle_erroring_state(e.message)
      {}
    end

    def all_events
      @all_events ||= begin
        recurring_overrides = fetch_recurring_overrides
        all_evts = []

        calendars.each do |cal|
          cal.events.each do |event|
            next unless event
            next if event.respond_to?(:recurrence_id) && event.recurrence_id

            if event.rrule.present?
              occurrences(event).each do |recurring_event|
                key = "#{event.uid}-#{recurring_event.dtstart.in_time_zone(time_zone)}"
                all_evts << prepare_event(recurring_overrides[key] || recurring_event)
              end
            else
              # process regular upcoming events
              all_evts << prepare_event(event)
            end
          end
        end

        all_evts
      end
    end

    def fetch_recurring_overrides
      overrides = {}
      calendars.each do |cal|
        cal.events.each do |event|
          next unless event

          if event.respond_to?(:recurrence_id) && event.recurrence_id
            overrides["#{event.uid}-#{event.recurrence_id.in_time_zone(time_zone)}"] = event
          end
        end
      end
      overrides
    end

    def filtered_events
      all_events.compact.uniq.select do |event|
        if event[:all_day]
          event[:date_time].between?(time_min, time_max)
        else
          event[:date_time].between?(time_min, time_max) || event[:end_full]&.between?(time_min, time_max)
        end
      end
    end

    # de-duplicates events where every param (except calname) matches -- helpful for family calendars where multiple entries otherwise exist for same event
    def unique_events
      filtered_events.compact.uniq { |evt| evt.values_at(:summary, :description, :status, :date_time, :all_day, :start_full, :end_full, :start, :end) }
    end

    def prepare_event(event)
      return if event_should_be_ignored?(event)

      # some params below are only needed for 1 or more event_layout options but not all
      # however all must be included as user may set event_layout==week, then create a mashup with event_layout==default
      layout_params = {
        start_full: event.dtstart&.in_time_zone(time_zone),
        end_full: guaranteed_end_time(event),
        start: event.dtstart&.in_time_zone(time_zone)&.strftime(formatted_time),
        end: event.dtend&.in_time_zone(time_zone)&.strftime(formatted_time)
      }

      {
        summary: event.summary.to_s || 'Busy', # likely a private event that doesn't share full details with connected calendar
        description: sanitize_description(event.description),
        status: event.status.to_s,
        date_time: event.dtstart.in_time_zone(time_zone),
        all_day: all_day_event?(event),
        calname: calname(event)
      }.merge(layout_params)
    end

    def recurring_event_start_date
      case event_layout
      when 'default', 'today_only', 'schedule'
        today_in_tz.to_date
      when 'week'
        today_in_tz.to_date - 7.days
      when 'month'
        today_in_tz.to_date.beginning_of_month
      when 'rolling_month'
        today_in_tz.to_date.beginning_of_week # today could be wednesday, but 'first_day' could be monday, so need earlier events
      end
    end

    def recurring_event_end_date
      case event_layout
      when 'today_only'
        today_in_tz.to_date + 2.days
      when 'default', 'week', 'month', 'rolling_month', 'schedule'
        time_max.to_date
      end
    end

    def calendars
      @calendars ||= begin
        cal_urls = line_separated_string_to_array(settings['ics_url']).map { it.gsub('webcal', 'https') }
        cals = []
        cal_urls.each do |url|
          response = fetch(url, headers:, timeout: 30, should_retry: false)
          next if response == nil # rubocop:disable Style/NilComparison
          next if response.body.nil? || response.body.empty?

          cals << Icalendar::Calendar.parse(response&.body&.gsub('Customized Time Zone', time_zone)).first
        end

        raise Plugins::Helpers::Errors::DataFetchError if cals.compact.empty?

        cals.uniq.compact
      end
    end

    def time_zone = user.tz || 'America/New_York'

    def time_max
      days_ahead = case event_layout
                   when 'month', 'rolling_month'
                     30 # don't simply get remainder of month; FullCalendar 'previews' next month near the end
                   when 'schedule'
                     14
                   else
                     7
                   end

      (now_in_tz.end_of_day + days_ahead.days)
    end

    def headers
      return {} unless settings['headers']

      string_to_hash(settings['headers'])
    end
  end
end
