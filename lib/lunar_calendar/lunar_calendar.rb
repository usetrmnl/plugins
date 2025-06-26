module Plugins
  class LunarCalendar < Base

    MOON_PHASES = [
      { name: "New Moon", keyname: 'new_moon', icon: "wi-moon-alt-new", age_range: 0..1, phase_order: 1 },
      { name: "Waxing Crescent", keyname: 'waxing_crescent', icon: "wi-moon-alt-waxing-crescent-3", age_range: 1..7, phase_order: 2 },
      { name: "First Quarter", keyname: 'first_quarter', icon: "wi-moon-alt-first-quarter", age_range: 7..8, phase_order: 3 },
      { name: "Waxing Gibbous", keyname: 'waxing_gibbous', icon: "wi-moon-alt-waxing-gibbous-3", age_range: 8..14, phase_order: 4 },
      { name: "Full Moon", keyname: 'full_moon', icon: "wi-moon-alt-full", age_range: 14..15, phase_order: 5 },
      { name: "Waning Gibbous", keyname: 'waning_gibbous', icon: "wi-moon-alt-waning-gibbous-3", age_range: 15..22, phase_order: 6 },
      { name: "Third Quarter", keyname: 'third_quarter', icon: "wi-moon-alt-third-quarter", age_range: 22..23, phase_order: 7 },
      { name: "Waning Crescent", keyname: 'waning_crescent', icon: "wi-moon-alt-waning-crescent-3", age_range: 23..29.53, phase_order: 8 }
    ].freeze

    def locals
      { phase_sequence:, current_phase:, next_phase:, illumination:, age:, next_full_moon:, next_new_moon: }
    end

    def phase_sequence = @phase_sequence ||= calculate_phase_sequence

    def calculate_phase_sequence
      return [] unless current_phase

      current_age = age
      current_date = today

      sequence = MOON_PHASES.map do |phase|
        days_to_phase = calculate_days_to_phase(current_age, phase[:age_range].begin)
        target_date = current_date + days_to_phase
        {
          name: phase_name(phase),
          icon: phase[:icon],
          current: phase == current_phase,
          date: l(target_date, format: "%b %d", locale:),
          date_full: target_date
        }
      end

      sorted = sequence.sort_by { |phase| phase[:date_full] }
      current_index = sorted.index { |phase| phase[:current] }

      start_idx = [current_index - 3, 0].max
      end_idx = [current_index + 3, sorted.length - 1].min

      sorted[start_idx..end_idx]
    end

    def phase_name(phase)
      t("renders.lunar_calendar.moon_phases.#{phase[:keyname]}", locale:)
    end

    def calculate_days_to_phase(current_age, target_age)
      lunar_month = 29.53058867

      forward_days = (target_age - current_age) % lunar_month
      backward_days = (current_age - target_age) % lunar_month

      if forward_days < backward_days
        forward_days.round
      else
        -backward_days.round
      end
    end

    def sequenced_phases
      looped_phases = MOON_PHASES * 3
      starting_idx = current_phase[:phase_order] - 1 + MOON_PHASES.count
      looped_phases[starting_idx - 3..starting_idx + 3]
    end

    def find_next_phase_date(target_age)
      30.times do |i|
        check_date = today + i
        age = moon_age(check_date)

        return check_date if (age - target_age).abs < 0.5
        return check_date if target_age.zero? && (age - target_age).to_i.zero?
      end
      today
    end

    def current_phase
      MOON_PHASES.find { |phase| phase[:age_range].include?(age) }
    end

    def next_phase
      next_phase_order = (current_phase[:phase_order] % MOON_PHASES.size) + 1
      next_phase_data = MOON_PHASES.find { |phase| phase[:phase_order] == next_phase_order }
      next_phase_date = find_next_phase_date(next_phase_data[:age_range].begin)
      {
        name: next_phase_data[:name],
        date: l(next_phase_date, format: "%b %d", locale:)
      }
    end

    def illumination
      ((1 - Math.cos(2 * Math::PI * age / 29.53)) / 2 * 100).round(1)
    end

    def age
      moon_age(today).round(1)
    end

    def next_full_moon
      phase_date = find_next_phase_date(15)
      l(phase_date, format: "%b %d", locale:)
    end

    def next_new_moon
      phase_date = find_next_phase_date(0)
      l(phase_date, format: "%b %d", locale:)
    end

    def moon_age(date)
      # Known new moon date
      known_new_moon = Date.new(2000, 1, 6)
      days_since = (date - known_new_moon).to_i
      lunar_month = 29.53058867

      ((days_since % lunar_month) + lunar_month) % lunar_month
    end

    def today
      user.datetime_now.to_date
    end
  end
end
