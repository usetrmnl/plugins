module Plugins
  class Todoist < Base

    def locals
      { tasks: }
    end

    class << self
      def redirect_url
        query = {
          response_type: 'code',
          client_id: Rails.application.credentials.plugins[:todoist][:client_id],
          scope: 'data:read',
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/todoist/redirect"
        }.to_query
        "https://todoist.com/oauth/authorize?#{query}"
      end

      def fetch_access_token(code)
        body = {
          grant_type: "authorization_code",
          client_id: Rails.application.credentials.plugins[:todoist][:client_id],
          client_secret: Rails.application.credentials.plugins[:todoist][:client_secret],
          redirect_uri: "#{Rails.application.credentials.base_url}/plugin_settings/todoist/redirect",
          code: code
        }
        response = HTTParty.post("https://todoist.com/oauth/access_token", body:)
        response.parsed_response['access_token']
      end

      def projects(access_token)
        response = HTTParty.get('https://api.todoist.com/rest/v2/projects', headers: headers(access_token))
        response.map { |m| { m['name'] => m['id'] } }&.push({ 'Today' => 'today' })
      end

      def headers(access_token) = { "Authorization" => "Bearer #{access_token}" }
    end

    private

    def task_url = "https://api.todoist.com/rest/v2/tasks"

    def tasks
      fetch(task_url, query:, headers: Plugins::Todoist.headers(access_token))
        .sort_by { Date.parse(it.dig('due', 'date') || (Date.today + 100.days).to_s) }
        .reject { today_view? ? (it.dig('due', 'date').blank? || Date.parse(it.dig('due', 'date')) > today) : false }
        .map do |it|
          {
            content: it['content'],
            due: it.dig('due', 'date').present? ? Date.parse(it.dig('due', 'date')).strftime("%d %b") : it.dig('due', 'string')
          }
        end
    end

    def query = today_view? ? {} : { project_id: settings['todoist_project_id'] }

    def access_token = settings.dig('todoist', 'access_token')

    def today_view? = settings['todoist_project_id'] == 'today'

    def today = user.datetime_now.end_of_day
  end
end
