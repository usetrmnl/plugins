module Plugins
  class LunchMoney < Base

    BASE_URL = 'https://dev.lunchmoney.app/v1'.freeze

    def locals
      { items: }
    end

    private

    def items
      case item_type
      when 'budgets' then budgets
      when 'accounts' then accounts
      end
    end

    def budgets
      resp = fetch(budgets_url, headers:)
      budget_data = JSON.parse(resp.body)
      raise AccessTokenExpired if budget_data.is_a?(Hash) && budget_data['message'] == 'Access token does not exist.'

      budget_data.map do |budget|
        next if budget['is_income'] # show only expenses by default

        [CGI.unescapeHTML(budget['category_name']), budget.dig('data', beginning_of_month, 'spending_to_base') || 0]
      end.compact
    rescue AccessTokenExpired => e
      handle_erroring_state(e.message)
      []
    end

    # user probably expects all items from "Accounts Overview" widget, which actually lives in 2 places (accounts, assets)
    def accounts
      resp = fetch(accounts_url, headers:)
      account_data = JSON.parse(resp.body)
      raise AccessTokenExpired if account_data.is_a?(Hash) && account_data['message'] == 'Access token does not exist.'

      resp = fetch(assets_url, headers:)
      asset_data = JSON.parse(resp.body)
      raise AccessTokenExpired if asset_data.is_a?(Hash) && asset_data['message'] == 'Access token does not exist.'

      accounts_map = account_data['plaid_accounts'].map do |account|
        [CGI.unescapeHTML(account['display_name'] || account['name']), account['balance']]
      end

      assets_map = asset_data['assets'].map do |asset|
        [CGI.unescapeHTML(asset['display_name'] || asset['name']), asset['balance']]
      end

      accounts_map + assets_map
    rescue AccessTokenExpired => e
      handle_erroring_state(e.message)
      []
    end

    def headers
      { "Authorization" => "Bearer #{settings['access_token']}" }
    end

    def item_type
      return 'budgets' unless settings['item_type'].present?

      settings['item_type']
    end

    def beginning_of_month = Date.today.beginning_of_month.to_s

    def end_of_month = Date.today.end_of_month.to_s

    def budgets_url = "#{BASE_URL}/budgets?start_date=#{beginning_of_month}&end_date=#{end_of_month}"

    def accounts_url = "#{BASE_URL}/plaid_accounts"

    def assets_url = "#{BASE_URL}/assets"
  end
end
