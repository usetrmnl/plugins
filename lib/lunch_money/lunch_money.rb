module Plugins
  class LunchMoney < Base

    def locals
      { budgets: }
    end

    private

    # rubocop:disable Style/MultilineBlockChain
    def budgets
      budget_data.map do |budget|
        next if budget['is_income'] # show only expenses by default

        [CGI.unescapeHTML(budget['category_name']), budget.dig('data', beginning_of_month, 'spending_to_base')]
      end.compact.sort_by { |_, v| -v } # sort high to low by $ amount
    end
    # rubocop:enable Style/MultilineBlockChain

    def budget_data
      HTTParty.get(budgets_url, headers:)
    end

    def base_url = 'https://dev.lunchmoney.app/v1'

    def headers
      { "Authorization" => "Bearer #{settings['access_token']}" }
    end

    def beginning_of_month
      Date.today.beginning_of_month.to_s
    end

    def end_of_month
      Date.today.end_of_month.to_s
    end

    def budgets_url = "#{base_url}/budgets?start_date=#{beginning_of_month}&end_date=#{end_of_month}"

  end
end
