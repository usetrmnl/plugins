# all ICS calendars look like this; they compile a hash of ~6 values and collections
module Plugins
  class OutlookCalendar < Base
    include Ics::Calendar

    def locals
      { events:, event_layout:, include_description:, first_day:, scroll_time:, today_in_tz: }
    end
  end
end

# module below is included in all ICS calendars (ex: Apple, Outlook, Fastmail, Nextcloud, etc)
module Ics
  module Calendar
    def events
      @prepare_events ||= prepare_events
    end

    def prepare_events
      all_events = []
      calendars.each do |cal|
        calendar_events = cal.events.sort_by(&:dtstart).select { |m| m.dtstart.in_time_zone(time_zone) >= cutoff_time }
        calendar_events.each do |event|
          next unless event

          # process recently created recurring events
          if event.rrule.present?
            occurences(event).each { |recurring_event| all_events << prepare_event(recurring_event) }
          else
            # process regular upcoming events
            all_events << prepare_event(event)
          end
        end
      end

      cached_recurring_events.each do |event|
        occurences(event).each { |recurring_event| all_events << prepare_event(recurring_event) }
      end

      all_events.compact.sort_by { |e| e[:date_time] }.group_by { |e| e[:day] }
    rescue ArgumentError => e
      handle_erroring_state(e.message) if e.message.include?("DNS name: nil")
      {}
    rescue Icalendar::Parser::ParseError => e
      handle_erroring_state(e.message)
      {}
    end

    def sync_recurring_events
      recurring_events = []
      calendars.each do |cal|
        calendar_events = cal.events.sort_by(&:dtstart).select { |m| m.dtstart >= DateTime.now - 5.years }
        calendar_events.each do |event|
          next unless event && event.rrule.present?

          recurring_events << {
            summary: event.summary,
            description: event.description,
            status: event.status,
            dtstart: event.dtstart,
            dtend: event.dtend,
            rrule: event.rrule.map(&:value_ical) # => ["FREQ=WEEKLY;UNTIL=20250617T120000Z;INTERVAL=1;BYDAY=TU;WKST=SU"]
          }
        end
      end

      plugin_settings.persistence_data['recurring_events'] = recurring_events
      plugin_settings.save
    end

    def cached_recurring_events
      r_events = plugin_settings.persistence_data['recurring_events'] || []

      r_events.map do |re|
        ie = Icalendar::Event.new

        ie.summary = re['summary']
        ie.description = re['description']
        ie.status = re['status']
        ie.dtstart = re['dtstart']&.to_datetime
        ie.dtend = re['dtend']&.to_datetime

        re['rrule'].each do |rule|
          ie.append_rrule Icalendar::Values::Recur.new(rule)
        end

        ie
      end
    end

    def prepare_event(event)
      return if event_should_be_ignored?(event)

      # some params below are only needed for 1 or more event_layout options but not all
      # however all must be included as user may set event_layout==week, then create a mashup with event_layout==default
      layout_params = {
        start_full: event.dtstart,
        end_full: event.dtend,
        start: event.dtstart&.strftime(time_format),
        end: event.dtend&.strftime(time_format)
      }

      {
        summary: event.summary || 'Busy', # likely a private event that doesn't share full details with connected calendar
        description: sanitize_description(event.description),
        status: event.status,
        date_time: event.dtstart,
        day: event.dtstart.in_time_zone(time_zone).strftime('%B %d'),
        all_day: all_day_event?(event)
      }.merge(layout_params)
    end

    def sanitize_description(description)
      description = description.join(', ') if description.is_a?(Icalendar::Values::Helpers::Array)
      Rails::Html::FullSanitizer.new.sanitize(description) || 'No description'
    end

    def occurences(event)
      recurrences = event.occurrences_between(recurring_event_start_date, recurring_event_end_date)

      recurrences.map do |recurrence|
        evt = event.dup
        evt.dtstart = recurrence.start_time.in_time_zone(time_zone)
        evt.dtend = recurrence.end_time.in_time_zone(time_zone)

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

    def all_day_event?(event)
      if event.rrule.present?
        (event.dtend.to_date - event.dtstart.to_date).to_i >= 1 # 24+ hours long, ex: 00:00 - 00:00 (next day)
      else
        # this check only works for regular events
        # cached_recurring_events lose data type artifacts
        event.dtstart.instance_of?(Icalendar::Values::Date)
      end
    end

    def calendars
      cal_urls = line_separated_string_to_array(settings['ics_url'])

      cals = []
      cal_urls.each do |url|
        response = fetch(url)
        raise Plugins::Helpers::Errors::DataFetchError if response.nil?

        cals << Icalendar::Calendar.parse(response&.body).first # is array but should just have 1
      end

      cals.uniq.compact
    end

    def time_zone = user.tz || 'America/New_York'

    def time_format
      if settings['time_format'] == 'am/pm'
        "%I:%M %p"
      else
        "%R"
      end
    end

    def event_should_be_ignored?(event)
      includes_ignored_phrases?(event) || ignore_based_on_status?(event) || ignore_based_on_time?(event)
    end

    def ignore_based_on_status?(event)
      return false if event.status&.downcase == 'confirmed' # always include confirmed events

      # include non-confirmed events if user prefers to see them (received requests for both options)
      # if this branch is reached, event.status == [nil, 'rejected'] etc
      settings['event_status_filter'] == 'confirmed_only'
    end

    def ignore_based_on_time?(event)
      event.dtend.in_time_zone(time_zone) < cutoff_time
    end

    def includes_ignored_phrases?(event)
      summary_includes = ignored_phrases.any? { |phrase| (event.summary || '').include?(phrase) }
      description_includes = ignored_phrases.any? { |phrase| (event.description || '').include?(phrase) }

      summary_includes || description_includes
    end

    def ignored_phrases
      return [] unless settings['ignore_phrases']

      settings['ignore_phrases'].gsub("\n", "").gsub("\r", "").split(',').map(&:squish)
    end

    def event_layout
      settings['event_layout']
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

    def today
      Date.today
    end

    def today_in_tz
      now_in_tz.to_date.to_s
    end

    def include_description
      return true unless settings['include_description'] # optional field, default value

      settings['include_description'] == 'yes'
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

    def cutoff_time
      settings['include_past_events'] == 'yes' ? now_in_tz.beginning_of_day : now_in_tz
    end
  end
end
