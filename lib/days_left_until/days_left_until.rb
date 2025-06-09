module Plugins
  class DaysLeftUntil < Base

    def locals
      { days_passed:, days_left:, percent_passed:, show_days_passed:, show_days_left:, message: }
    end

    private

    def start_date
      return plugin_settings.created_at.to_date.to_s unless settings['start_date'].present?

      settings['start_date']
    end

    def end_date = settings['end_date']

    def days_passed
      (today - start_date.to_date).to_i
    end

    def days_left
      (end_date.to_date - today).to_i
    end

    def percent_passed
      ((days_passed.to_f / (days_passed + days_left)) * 100).round
    rescue FloatDomainError
      100
    end

    def show_days_passed
      return true unless settings['show_days_passed'].present?

      settings['show_days_passed'] == 'yes'
    end

    def show_days_left
      return true unless settings['show_days_left'].present?

      settings['show_days_left'] == 'yes'
    end

    def today = user.datetime_now.to_date

    # TODO: NOT in use
    def message
      settings['message']
    end
  end
end
