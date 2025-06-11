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
module Calendar
  module Ics
    include Helper

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
        event.exdate.map! do |item|
          if item.is_a?(Icalendar::Values::Helpers::Array)
            item.map! { it.in_time_zone(time_zone) }
          else
            item.in_time_zone(time_zone)
          end
        end
      end

      begin
        recurrences = event.occurrences_between(recurring_event_start_date, recurring_event_end_date)
      rescue StandardError => e
        recurrences = []
        Rails.logger.error("[PluginSetting ID: #{plugin_settings.id}] #{e.message} (calname: #{calname(event)}, uid: #{event.uid})")
      end

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
      when 'default', 'today_only'
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
      when 'default', 'week', 'month', 'rolling_month'
        time_max.to_date
      end
    end

    def guaranteed_end_time(event)
      g_et = event.dtend&.in_time_zone(time_zone)
      g_et = (event.dtstart&.in_time_zone(time_zone)&.+ 24.hours) if g_et.nil?
      g_et
    end

    def single_day_event?(event)
      guaranteed_end_time(event) - event.dtstart&.in_time_zone(time_zone) == 86400
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
        next if response.body.nil?

        cals << Icalendar::Calendar.parse(response&.body&.gsub('Customized Time Zone', time_zone)).first
      end

      raise Plugins::Helpers::Errors::DataFetchError if cals.compact.empty?

      cals.uniq.compact
    end

    def time_zone = user.tz || 'America/New_York'

    def event_should_be_ignored?(event)
      return false if event.instance_of?(Icalendar::Recurrence::Occurrence)
      return true if empty?(event)

      includes_ignored_phrases?(event) || ignore_based_on_status?(event) || ignore_based_on_time?(event)
    end

    # some events have ~all nil attributes (time, summary, description, etc)
    def empty?(event)
      event.dtstart.nil? && event.dtend.nil?
    end

    def includes_ignored_phrases?(event)
      summary_includes = ignored_phrases.any? { |phrase| (event.summary || '').include?(phrase) }
      description_includes = ignored_phrases.any? { |phrase| (event.description || '').include?(phrase) }

      summary_includes || description_includes
    end

    # consider changing this to use 'start' vs 'end'
    def ignore_based_on_time?(event)
      end_time = guaranteed_end_time(event)
      end_time <= cutoff_time
    end

    def time_max
      days_ahead = case event_layout
                   when 'month', 'rolling_month'
                     30 # don't simply get remainder of month; FullCalendar 'previews' next month near the end
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
