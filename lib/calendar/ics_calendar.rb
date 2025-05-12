# all ICS calendars look like this; they compile a hash of ~6 values and collections
module Plugins
  class OutlookCalendar < Base
    include Ics::Calendar

    def locals
      { events:, event_layout:, include_description:, include_event_time:, first_day:, scroll_time:, time_format:, today_in_tz: }
    end
  end
end

# module below is included in all ICS calendars (ex: Apple, Outlook, Fastmail, Nextcloud, etc)
module Ics
  # rubocop:disable Metrics/ModuleLength
  module Calendar
    def events
      @prepare_events ||= prepare_events
    end

    def prepare_events
      unique_events.sort_by { |e| e[:date_time] }.group_by { |e| e[:day] }
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
        all_evts = []
        calendars.each do |cal|
          cal.events.each do |event|
            next unless event

            if event.rrule.present?
              occurences(event).each { |recurring_event| all_evts << prepare_event(recurring_event) }
            else
              # process regular upcoming events
              all_evts << prepare_event(event)
            end
          end
        end

        all_evts
      end
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
      filtered_events.compact.uniq { |evt| evt.values_at(:summary, :description, :status, :date_time, :day, :all_day, :start_full, :end_full, :start, :end) }
    end

    def prepare_event(event)
      return if event_should_be_ignored?(event)

      # some params below are only needed for 1 or more event_layout options but not all
      # however all must be included as user may set event_layout==week, then create a mashup with event_layout==default
      layout_params = {
        start_full: event.dtstart&.in_time_zone(time_zone),
        end_full: event.dtend&.in_time_zone(time_zone),
        start: event.dtstart&.in_time_zone(time_zone)&.strftime(formatted_time),
        end: event.dtend&.in_time_zone(time_zone)&.strftime(formatted_time)
      }

      {
        summary: event.summary.to_s || 'Busy', # likely a private event that doesn't share full details with connected calendar
        description: sanitize_description(event.description),
        status: event.status.to_s,
        date_time: event.dtstart.in_time_zone(time_zone),
        day: formatted_day(event),
        all_day: all_day_event?(event),
        calname: calname(event)
      }.merge(layout_params)
    end

    def sanitize_description(description)
      description = description.join(', ') if description.is_a?(Icalendar::Values::Helpers::Array)
      return '' if description.nil?

      Rails::Html::FullSanitizer.new.sanitize(description.strip.split("\n").first&.strip || '')
    end

    def calname(event)
      event.parent.custom_properties.dig('x_wr_calname', 0)
    end

    def occurences(event)
      if event.dtstart.is_a?(Icalendar::Values::Date)
        event.dtstart = event.dtstart.in_time_zone(time_zone)
        event.dtend = (event.dtend || event.dtstart).in_time_zone(time_zone)
      end

      recurrences = event.occurrences_between(recurring_event_start_date, recurring_event_end_date)

      recurrences.map do |recurrence|
        evt = event.dup
        evt.dtstart = recurrence.start_time.in_time_zone(time_zone).change(
          hour: event.dtstart.in_time_zone(time_zone).hour,
          min: event.dtstart.in_time_zone(time_zone).min
        )
        evt.dtend = recurrence.end_time.in_time_zone(time_zone).change(
          hour: event.dtend.in_time_zone(time_zone).hour,
          min: event.dtend.in_time_zone(time_zone).min
        )
        evt
      end
    end

    def recurring_event_start_date
      case event_layout
      when 'default'
        today_in_tz.to_date
      when 'week'
        today_in_tz.to_date - 7.days
      when 'month'
        today_in_tz.to_date.beginning_of_month
      end
    end

    def recurring_event_end_date
      case event_layout
      when 'default'
        today_in_tz.to_date + 4.days
      when 'week'
        today_in_tz.to_date + 7.days
      when 'month'
        today_in_tz.to_date.end_of_month
      end
    end

    def formatted_day(event)
      event.dtstart.in_time_zone(time_zone).strftime('%A, %B %-d')
    end

    def all_day_event?(event)
      return true if event.dtstart.to_datetime.hour.zero? && event.dtstart.to_datetime.min.zero?
      return true if event.dtstart.instance_of?(Icalendar::Values::Date)

      if event.rrule.present? && event.dtend
        # 24+ hours long, ex: 00:00 - 00:00 (next day)
        return (event.dtend.to_date - event.dtstart.to_date).to_i >= 1
      end

      false
    end

    def calendars
      cal_urls = line_separated_string_to_array(settings['ics_url']).map { it.gsub('webcal', 'https') }

      cals = []
      cal_urls.each do |url|
        response = HTTParty.get(url, headers:, verify: false) ## Not using fetch, as fetch has a timeout of 10s with 3 retries so 30s in total

        cals << Icalendar::Calendar.parse(response&.body).first unless response.nil?
      end

      raise Plugins::Helpers::Errors::DataFetchError if cals.compact.empty?

      cals.uniq.compact
    end

    def time_zone = user.tz || 'America/New_York'

    def formatted_time
      return "%-I:%M %p" if time_format == 'am/pm'

      "%R"
    end

    def time_format
      settings['time_format'] || 'am/pm'
    end

    def event_should_be_ignored?(event)
      return false if event.instance_of?(Icalendar::Recurrence::Occurrence)

      includes_ignored_phrases?(event) || ignore_based_on_status?(event) || ignore_based_on_time?(event)
    end

    def ignore_based_on_status?(event)
      return false if event.status&.downcase == 'confirmed' # always include confirmed events

      # include non-confirmed events if user prefers to see them (received requests for both options)
      # if this branch is reached, event.status == [nil, 'rejected'] etc
      settings['event_status_filter'] == 'confirmed_only'
    end

    def includes_ignored_phrases?(event)
      summary_includes = ignored_phrases.any? { |phrase| (event.summary || '').include?(phrase) }
      description_includes = ignored_phrases.any? { |phrase| (event.description || '').include?(phrase) }

      summary_includes || description_includes
    end

    # consider changing this to use 'start' vs 'end'
    def ignore_based_on_time?(event)
      end_time = event.dtend&.in_time_zone(time_zone)
      return false if end_time.nil?

      end_time < cutoff_time
    end

    # some users prefer to maintain 'state' and see already-passed events
    # default is to ignore events already completed on this same day
    def cutoff_time
      settings['include_past_events'] == 'yes' ? time_min : now_in_tz
    end

    def ignored_phrases
      return [] unless settings['ignore_phrases']

      settings['ignore_phrases'].gsub("\n", "").gsub("\r", "").split(',').map(&:squish)
    end

    def event_layout
      settings['event_layout']
    end

    def time_min
      days_behind = case event_layout
                    when 'month'
                      30 # don't simply get remainder of month; FullCalendar 'previews' next month near the end
                    else
                      7
                    end

      (beginning_of_day - days_behind.days)
    end

    def time_max
      days_ahead = case event_layout
                   when 'month'
                     30 # don't simply get remainder of month; FullCalendar 'previews' next month near the end
                   else
                     7
                   end

      (now_in_tz.end_of_day + days_ahead.days)
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

    def beginning_of_day
      now_in_tz.beginning_of_day
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

    def headers
      return {} unless settings['headers']

      string_to_hash(settings['headers'])
    end

    # ability to hard-code each day's first time slot in event_layout=week mode
    # by default we lookup the earliest event within the period, but some users
    # prefer to sacrifice morning visibility to see more throughout the day
    def scroll_time
      return settings['scroll_time'] if settings['scroll_time'].present?

      events.values.flatten.reject { |e| e[:all_day] }.map { |e| e[:start_full].to_time.strftime("%H:00:00") }.min || '08:00:00'
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
