module Calendar
  module Helper
    def cutoff_time
      case [event_layout, include_past_event?]
      when ['default', true], ['today_only', true], ['week', true], ['week', false], ['month', false], ['rolling_month', false]
        beginning_of_day
      when ['default', false], ['today_only', false] # this is useful for busy calendar to remove event that have elapsed.
        now_in_tz
      when ['month', true], ['rolling_month', true]
        time_min
      end
    end

    def event_layout = settings['event_layout']

    def include_past_event? = settings['include_past_events'] == 'yes'

    def now_in_tz = user.datetime_now

    # required to ensure locals data has a 'diff' at least 1x per day
    # given week/month view 'highlight' current day
    # without this local, previous day will be highlighted if events dont change
    def today_in_tz = now_in_tz.to_date.to_s

    def beginning_of_day = now_in_tz.beginning_of_day

    def time_min
      days_behind = case event_layout
                    when 'month', 'rolling_month'
                      30 # TODO: improve this to not store all 30 days, as right now we endup storing 30+3=60 days events.
                    else
                      7
                    end

      (beginning_of_day - days_behind.days)
    end

    def first_day = Date.strptime(settings['first_day'], '%a').wday

    def ignore_based_on_status?(event)
      if event.instance_of?(Icalendar::Event)
        return true if event.status == 'CANCELLED' && event.dtstart.nil?
        return true if event.exdate.flatten.filter { |exception_date| event.dtstart&.to_datetime == exception_date.to_datetime }.present?
      end
      return false if event.status&.downcase == 'confirmed' # always include confirmed events

      # include non-confirmed events if user prefers to see them (received requests for both options)
      # if this branch is reached, event.status == [nil, 'rejected'] etc
      settings['event_status_filter'] == 'confirmed_only'
    end

    def include_description
      return true unless settings['include_description'] # backward compatible default value

      settings['include_description'] == 'yes'
    end

    def include_event_time
      return false unless settings['include_event_time'] # backward compatible default value

      settings['include_event_time'] == 'yes'
    end

    def ignored_phrases
      return [] unless settings['ignore_phrases']

      settings['ignore_phrases'].gsub("\n", "").gsub("\r", "").split(',').map(&:squish)
    end

    def time_format = settings['time_format'] || 'am/pm'

    def formatted_time
      return "%-I:%M %p" if time_format == 'am/pm'

      "%R"
    end

    # ability to hard-code each day's first time slot in event_layout=week mode
    # by default we lookup the earliest event within the period, but some users
    # prefer to sacrifice morning visibility to see more throughout the day
    def scroll_time
      return settings['scroll_time'] if settings['scroll_time'].present?

      events.reject { |e| e[:all_day] }.map { |e| e[:start_full].to_time.strftime("%H:00:00") }.min || '08:00:00'
    end

    def scroll_time_end
      return settings['scroll_time_end'] if settings['scroll_time_end'].present?

      events.reject { |e| e[:all_day] }.map { |e| e[:end_full].to_time.strftime("%H:00:00") }.max || '24:00:00' # same default: https://fullcalendar.io/docs/slotMaxTime
    end

    def zoom_mode
      settings['zoom_mode'] == 'yes'
    end
  end
end
