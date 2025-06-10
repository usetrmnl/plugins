module Plugins
  class Todoist < Base
    TASKS_URL = 'https://api.todoist.com/rest/v2/tasks'.freeze

    # Extracted from Todoist Web App API Calls to `https://app.todoist.com/api/v9.223/sync`
    FILTER_DATE_OPTIONS_MAP = {
      all:          nil,
      today:        'overdue | today',
      this_week:    'due before: next week',
      next_7_days:  'overdue | next 7 days',
      this_month:   'due before: first day',
      next_30_days: 'overdue | next 30 days',
      no_date:      'no date'
    }

    FILTER_DEADLINE_OPTIONS_MAP = {
      all:          nil,
      today:        'deadline before: tomorrow',
      this_week:    'deadline before: next week',
      next_7_days:  'deadline before: in 7 days',
      this_month:   'deadline before: first day',
      next_30_days: 'deadline before: in 30 days',
      no_deadline:  'no deadline'
    }

    TaskDue = Struct.new(
      :date,
      :is_recurring,
      :datetime,
      :string,
      :timezone,
      keyword_init: true
    ) do
      def initialize(*args)
        super
        self.date     = Date.parse(date) if date
        self.datetime = DateTime.parse(datetime) if datetime
      end
    end

    TaskDeadline = Struct.new(
      :date,
      keyword_init: true
    ) do
      def initialize(*args)
        super
        self.date = Date.parse(date) if date
      end
    end

    Task = Struct.new(
      :creator_id,
      :created_at,
      :assignee_id,
      :assigner_id,
      :comment_count,
      :is_completed,
      :content,
      :description,
      :due,
      :deadline,
      :duration,
      :id,
      :labels,
      :order,
      :priority,
      :project_id,
      :section_id,
      :parent_id,
      :url,
      keyword_init: true
    ) do
      def initialize(*args)
        super
        self.due        = TaskDue.new(due) if due
        self.deadline   = TaskDeadline.new(deadline) if deadline
        self.created_at = DateTime.parse(created_at) if created_at
      end
    end

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

      # @see https://developer.todoist.com/rest/v2/#get-all-projects
      def projects(access_token)
        response = HTTParty.get('https://api.todoist.com/rest/v2/projects', headers: headers(access_token))
        response.map { |m| { m['name'] => m['id'] } }&.push({ 'Today' => 'today' })
      end

      # @see https://developer.todoist.com/rest/v2/#get-all-personal-labels
      def labels(access_token)
        response = HTTParty.get('https://api.todoist.com/rest/v2/labels', headers: headers(access_token))
        response.map { |m| { m['name'] => m['name'] } }
      end

      def headers(access_token) = { "Authorization" => "Bearer #{access_token}" }
    end

    private

    def access_token = settings.dig('todoist', 'access_token')

    def tasks
      response = fetch(TASKS_URL, query:, headers: Plugins::Todoist.headers(access_token))

      tasks = response.map { Task.new(it) }
      tasks = tasks_sort(tasks)
      tasks = tasks_group(tasks)

      tasks_format(tasks)
    end

    def query
      if today_view?
        {
          filter: tasks_filter_today
        }
      else
        {
          project_id: settings['todoist__project_id'],
          filter:     tasks_filter_project
        }
      end
    end

    def today_view? = settings['todoist__project_id'] == 'today'
    def today = user.datetime_now.end_of_day

    # @note The internal Todoist API wraps the "Today" view, so this is a best guess
    #   to match the behavior of the Todoist Web App.
    def tasks_filter_today
      tasks_filter_compile([
        FILTER_DATE_OPTIONS_MAP.fetch(:today),
        FILTER_DEADLINE_OPTIONS_MAP.fetch(:today)
      ], joiner: '|')
    end

    # @return [String] `(@label) & (p1 | p2 | p3) & (due before: next week) & (deadline before: tomorrow)`
    def tasks_filter_project
      # Order based on observed Todoist Web App API Calls
      tasks_filter_compile([
        filter_labels,
        filter_priority,
        filter_date,
        filter_deadline
      ])
    end

    # @return [String] `today` or `overdue | today`
    def tasks_filter_date
      FILTER_DATE_OPTIONS_MAP.fetch(settings['todoist__filter_date'])
    end

    # @return [String] `deadline before: tomorrow`
    def tasks_filter_deadline
      FILTER_DEADLINE_OPTIONS_MAP.fetch(settings['todoist__filter__deadline'])
    end

    # @return [String] `p1` or `(p1 | p2)`
    def tasks_filter_priority
      settings['todoist__filter__priority']
    end

    # @return [String] `@thing` or `(@thing_one | @thing_two)`
    def tasks_filter_labels
      return if settings['todoist__filter__labels'].blank?

      settings['todoist__filter__labels'].map { "@#{_1}" }
    end

    def tasks_filter_compile(filter_groups, joiner: '&')
      filter_groups.compact.map do |filter_group|
        tasks_filter_group_join(filter_group)
      end.join(" #{joiner} ")
    end

    def tasks_filter_group_join(filter_group)
      "(#{filter_group.join(' | ')})"
    end

    def tasks_sort(tasks)
      case settings['todoist__sort__sorting']
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

    def tasks_sort_by_manual(tasks)
      tasks.sort_by(&:order)
    end

    def tasks_sort_by_name(tasks)
      tasks.sort_by do |task|
        task.content.downcase
      end
    end

    def tasks_sort_by_date(tasks)
      tasks.sort_by do |task|
        task.due&.date || Date::Infinity.new
      end
    end

    def tasks_sort_by_date_added(tasks)
      tasks.sort_by(&:created_at)
    end

    def tasks_sort_by_deadline(tasks)
      tasks.sort_by do |task|
        task.deadline&.date || Date::Infinity.new
      end
    end

    def tasks_sort_by_priority(tasks)
      tasks.sort_by(&:priority)
    end

    def tasks_group(tasks)
      case settings['todoist__group__grouping']
      when 'date'
        tasks_group_by_date(tasks)
      when 'date_added'
        tasks_group_by_date_added(tasks)
      when 'deadline'
        tasks_group_by_deadline(tasks)
      when 'priority'
        tasks_group_by_priority(tasks)
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
    def tasks_group_by_date(tasks)
      tasks.group_by do |task|
        tasks_group_format_date_title(task.due&.date, none: 'No date')
      end
    end

    # May 25 ‧ Today ‧ Sunday
    # Jun 6 ‧ Friday
    def tasks_group_by_date_added(tasks)
      groups = tasks.group_by do |task|
        tasks_group_format_date(task.created_at)
      end
    end

    # Overdue
    # May 25 ‧ Today ‧ Sunday
    # Jun 6 ‧ Friday
    # No deadline
    def tasks_group_by_deadline(tasks)
      tasks.group_by do |task|
        tasks_group_format_date_title(task.deadline&.date, none: 'No deadline')
      end
    end

    # Priority 1
    # Priority 2
    # Priority 3
    # Priority 4
    def tasks_group_by_priority(tasks)
      tasks.group_by do |task|
        "Priority #{task.priority}"
      end
    end

    # {Label}
    # No label
    def tasks_group_by_labels(tasks)
      groups = {}

      tasks.each do |task|
        if task.labels.blank?
          groups['No label'] ||= []
          groups['No label'] << task
        else
          task.labels&.each do |label|
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
        fail "Invalid tasks format: #{tasks.class}"
      end
    end

    def tasks_extract(task)
      {
        is_completed:     task.is_completed,
        content:          task.content,
        description:      task.description,
        due_date:         task.due&.date,
        due_is_recurring: task.due&.is_recurring,
        dateline_date:    task.deadline&.date,
      }
    end
  end
end
