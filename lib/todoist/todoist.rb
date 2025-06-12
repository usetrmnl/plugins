module Plugins
  class Todoist < Base

    LEGACY_TASKS_URL = 'https://api.todoist.com/rest/v2/tasks'.freeze
    TASKS_URL = 'https://api.todoist.com/api/v1/tasks/filter'.freeze

    def locals
      { tasks: }
    end

    # Extracted from Todoist Web App API Calls to `https://app.todoist.com/api/v9.223/sync`
    FILTER_DATE_OPTIONS_MAP = {
      all: nil,
      today: 'overdue | today',
      this_week: 'due before: next week',
      next_7_days: 'overdue | next 7 days',
      this_month: 'due before: first day',
      next_30_days: 'overdue | next 30 days',
      no_date: 'no date'
    }.with_indifferent_access

    FILTER_DEADLINE_OPTIONS_MAP = {
      all: nil,
      today: 'deadline before: tomorrow',
      this_week: 'deadline before: next week',
      next_7_days: 'deadline before: in 7 days',
      this_month: 'deadline before: first day',
      next_30_days: 'deadline before: in 30 days',
      no_deadline: 'no deadline'
    }.with_indifferent_access

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

      # @see https://developer.todoist.com/rest/v2/#get-all-projects
      def projects(access_token)
        response = HTTParty.get('https://api.todoist.com/rest/v2/projects', headers: headers(access_token))
        response.parsed_response&.map { |m| { m['name'] => m['id'] } }&.push({ 'Today' => 'today' })
      end

      # @see https://developer.todoist.com/rest/v2/#get-all-personal-labels
      def labels(access_token)
        response = HTTParty.get('https://api.todoist.com/rest/v2/labels', headers: headers(access_token))
        response.map { |m| { m['name'] => m['name'] } }
      end

      def headers(access_token) = { "Authorization" => "Bearer #{access_token}" }
    end

    private

    def tasks
      if filters_present?
        response = fetch(TASKS_URL, query:, headers: Plugins::Todoist.headers(access_token))
        tasks = response.parsed_response['results']

        tasks = tasks_sort(tasks)
        tasks = tasks_group(tasks)

        tasks_format(tasks)
      else
        tasks_legacy
      end
    end

    # non-exhaustive list that helps determine if user has set up refactored version of this plugin (2025-06-10 onwards)
    def filters_present?
      settings['filter_date'].present? && settings['sort_grouping'].present? && settings['sort_direction'].present?
    end

    def query
      if today_view?
        {
          query: filter_today
        }
      else
        {
          query: "##{project_name},#{tasks_filter_project}"
        }
      end
    end

    def tasks_legacy
      fetch(LEGACY_TASKS_URL, query: query_legacy, headers: Plugins::Todoist.headers(access_token))
        .sort_by { Date.parse(it.dig('due', 'date') || (Date.today + 100.days).to_s) }
        .reject { today_view? ? (it.dig('due', 'date').blank? || Date.parse(it.dig('due', 'date')) > today) : false }
        .map do |it|
          {
            content: it['content'],
            due: it.dig('due', 'date').present? ? Date.parse(it.dig('due', 'date')).strftime("%d %b") : it.dig('due', 'string')
          }
        end
    end

    def query_legacy = today_view? ? {} : { project_id: project_id }

    def project_name
      # don't store this permanently in case user changes name
      # return settings['project_name'] if settings['project_name'].present?

      projects = Plugins::Todoist.projects(access_token)
      projects.find { |p| p.values.to_s.include? settings['todoist_project_id'].to_s }.keys.first
    end

    def project_id
      settings['todoist_project_id']
    end

    # @note The internal Todoist API wraps the "Today" view, so this is a best guess
    #   to match the behavior of the Todoist Web App.
    def filter_today
      filter_compile([
                       FILTER_DATE_OPTIONS_MAP.fetch(:today),
                       FILTER_DEADLINE_OPTIONS_MAP.fetch(:today)
                     ], joiner: '|')
    end

    # @return [String] `(@label) & (p1 | p2 | p3) & (due before: next week) & (deadline before: tomorrow)`
    def tasks_filter_project
      # Order based on observed Todoist Web App API Calls
      filter_compile([
                       filter_labels,
                       filter_priority,
                       filter_date,
                       filter_deadline
                     ])
    end

    # @return [String] `today` or `overdue | today`
    def filter_date
      FILTER_DATE_OPTIONS_MAP.fetch(settings['filter_date'])
    end

    # @return [String] `deadline before: tomorrow`
    def filter_deadline
      FILTER_DEADLINE_OPTIONS_MAP.fetch(settings['filter_deadline'])
    end

    # @return [String] `p1` or `(p1 | p2)`
    def filter_priority
      settings['filter_priority']
    end

    # @return [String] `@thing` or `(@thing_one | @thing_two)`
    def filter_labels
      return if settings['filter_labels'].blank?

      settings['filter_labels'].map { "@#{it}" }
    end

    def filter_compile(filter_groups, joiner: '&')
      filter_groups.compact.map do |filter_group|
        filter_group_join(filter_group)
      end.join(" #{joiner} ")
    end

    def filter_group_join(filter_group)
      filter_group = [filter_group] if filter_group.is_a?(String)
      "(#{filter_group.join(' | ')})"
    end

    def tasks_sort(tasks)
      case settings['sort_sorting']
      when 'manual'
        sort_by_manual(tasks)
      when 'name'
        sort_by_name(tasks)
      when 'date'
        sort_by_date(tasks)
      when 'date_added'
        sort_by_date_added(tasks)
      when 'deadline'
        sort_by_deadline(tasks)
      when 'priority'
        sort_by_priority(tasks)
      else
        tasks
      end
    end

    def sort_by_manual(tasks)
      tasks.sort_by { it['order'] }
    end

    def sort_by_name(tasks)
      tasks.sort_by do |task|
        task['content'].downcase
      end
    end

    def sort_by_date(tasks)
      tasks.sort_by do |task|
        task.dig('due', 'date') ? Date.parse(task.dig('due', 'date')) : Date::Infinity.new
      end
    end

    def sort_by_date_added(tasks)
      tasks.sort_by { it['created_at'] }
    end

    def sort_by_deadline(tasks)
      tasks.sort_by do |task|
        task.dig('deadline', 'date') ? Date.parse(task.dig('deadline', 'date')) : Date::Infinity.new
      end
    end

    def sort_by_priority(tasks)
      tasks.sort_by { it['priority'] }
    end

    def tasks_group(tasks)
      case settings['group_grouping']
      when 'date'
        group_by_date(tasks)
      when 'date_added'
        group_by_date_added(tasks)
      when 'deadline'
        group_by_deadline(tasks)
      when 'priority'
        group_by_priority(tasks)
      when 'labels'
        tasks_group_by_labels(tasks)
      else
        tasks
      end
    end

    # Overdue
    # May 25 ‧ Today ‧ Sunday
    # Jun 6 ‧ Friday
    # No date
    def group_by_date(tasks)
      tasks.group_by do |task|
        tasks_group_format_date_title(task.dig('due', 'date'), none: 'No date')
      end
    end

    # May 25 ‧ Today ‧ Sunday
    # Jun 6 ‧ Friday
    def group_by_date_added(tasks)
      tasks.group_by do |task|
        tasks_group_format_date(task['created_at'])
      end
    end

    # Overdue
    # May 25 ‧ Today ‧ Sunday
    # Jun 6 ‧ Friday
    # No deadline
    def group_by_deadline(tasks)
      tasks.group_by do |task|
        tasks_group_format_date_title(task.dig('deadline', 'date'), none: 'No deadline')
      end
    end

    # Priority 1
    # Priority 2
    # Priority 3
    # Priority 4
    def group_by_priority(tasks)
      tasks.group_by do |task|
        "Priority #{task['priority']}"
      end
    end

    # {Label}
    # No label
    def tasks_group_by_labels(tasks)
      groups = {}

      tasks.each do |task|
        if task['labels'].empty?
          groups['No label'] ||= []
          groups['No label'] << task
        else
          task['labels']&.each do |label|
            groups[label] ||= []
            groups[label] << task
          end
        end
      end

      groups
    end

    # Overdue
    # May 25 ‧ Today ‧ Sunday
    # Jun 6 ‧ Friday
    # {No date}
    def tasks_group_format_date_title(date, none:)
      if date.nil?
        none
      elsif date < today
        'Overdue'
      else
        tasks_group_format_date(date)
      end
    end

    def tasks_group_format_date(date)
      segments = [date.strftime('%b %d'), 'Today', date.strftime('%A')]

      segments.delete_at(1) if date != today

      segments.join(' ‧ ')
    end

    def tasks_format(data)
      case data
      when Array
        data.map { tasks_extract(it) }
      when Hash
        data.transform_values do |tasks|
          tasks.map { tasks_extract(it) }
        end
      else
        raise "Invalid tasks format: #{tasks.class}"
      end
    end

    def tasks_extract(task)
      {
        is_completed: task['is_completed'],
        content: task['content'],
        description: task['description'],
        due_date: task.dig('due', 'date'),
        due_is_recurring: task.dig('due', 'is_recurring'),
        dateline_date: task.dig('deadline', 'date')
      }
    end

    def access_token = settings.dig('todoist', 'access_token')

    def today_view? = project_id == 'today'

    def today = user.datetime_now.end_of_day
  end
end
