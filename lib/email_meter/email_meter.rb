module Plugins
  class EmailMeter < Base

    def locals
      { metrics: }
    end

    private

    def base_url = 'https://api02.emailmeter.com/bqi'

    def headers
      { authorization: "Token #{settings['api_token']}" }
    end

    def metrics
      {
        messages_sent:,
        recipients:,
        avg_response_time:,
        messages_received:,
        senders:
      }
    end

    def timestamp_from
      lookback_period.days.ago.to_date.to_s
    end

    def timestamp_to
      Time.now.in_time_zone(user.tz).to_date.to_s
    end

    def messages_sent
      endpoint = "/total_sent_emails?timestamp_from=#{timestamp_from}&timestamp_to=#{timestamp_to}"
      response = fetch(base_url + endpoint, headers: headers)
      response.dig(0, 'count') || 0
    end

    def recipients
      endpoint = "/sent_messages_list_by_recipient?timestamp_from=#{timestamp_from}&timestamp_to=#{timestamp_to}"
      response = fetch(base_url + endpoint, headers: headers)
      response.count
    end

    def avg_response_time
      endpoint = "/reply_times?timestamp_from=#{timestamp_from}&timestamp_to=#{timestamp_to}"
      response = fetch(base_url + endpoint, headers: headers)
      avg_reply_time = response.dig(0, 'avg_reply_time') || 0
      ActiveSupport::Duration.build(avg_reply_time).parts # => {:hours=>22, :minutes=>21, :seconds=>22.639999999999418}
    end

    def messages_received
      endpoint = "/total_received_emails?timestamp_from=#{timestamp_from}&timestamp_to=#{timestamp_to}"
      response = fetch(base_url + endpoint, headers: headers)
      response.dig(0, 'count') || 0
    end

    def senders
      endpoint = "/received_messages_list_by_sender?timestamp_from=#{timestamp_from}&timestamp_to=#{timestamp_to}"
      response = fetch(base_url + endpoint, headers: headers)
      response.count
    end
  end
end
