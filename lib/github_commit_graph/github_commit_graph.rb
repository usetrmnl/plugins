module Plugins
  class GithubCommitGraph < Base
    def locals
      { username:, contributions:, stats: }
    end

    private

    def username = settings['username']

    def contributions
      @contributions ||= begin
        query = "query($userName:String!) {
          user(login: $userName){
            contributionsCollection {
              contributionCalendar {
                totalContributions
                weeks {
                  contributionDays {
                    contributionCount
                    date
                  }
                }
              }
            }
          }
        }"
        body = { query: query, variables: { userName: username } }
        resp = post('https://api.github.com/graphql', body: body.to_json, headers: headers)
        data = resp.dig('data', 'user', 'contributionsCollection', 'contributionCalendar')

        if data.nil?
          { errors: "Cannot fetch data for #{username}" }
        else
          {
            total: data['totalContributions'],
            commits: data['weeks'].map(&:deep_symbolize_keys)
          }
        end
      end
    end

    def headers
      { 'authorization' => "Bearer #{Rails.application.credentials.plugins.github_commit_graph_token}" }
    end

    # re "Streak" calculations, these may be wrong for some users
    # either A), the 'time-zone' header does not work (https://github.com/orgs/community/discussions/20898)
    # or B), the time zone is only inferred by the token's owner, us! (https://docs.github.com/en/rest/metrics/statistics?apiVersion=2022-11-28#get-the-hourly-commit-count-for-each-day)
    def stats
      return {} if contributions[:commits].nil?

      days = contributions[:commits].flat_map { |week| week[:contributionDays] }
      sorted_days = days.sort_by { |day| Date.parse(day[:date]) }

      {
        longest_streak: longest_streak(sorted_days),
        current_streak: current_streak(sorted_days),
        max_contributions: days.map { |day| day[:contributionCount] }.max,
        average_contributions: average_contributions(days)
      }
    end

    def average_contributions(days)
      total_contributions = days.sum { |day| day[:contributionCount] }
      (total_contributions.to_f / days.size).round(2)
    end

    def longest_streak(days)
      longest = current = 0
      days.each do |day|
        if day[:contributionCount].positive?
          current += 1
          longest = [longest, current].max
        else
          current = 0
        end
      end
      longest
    end

    def current_streak(days)
      streak = 0
      streak += 1 if days.last[:contributionCount].positive?

      days[0..-2].reverse_each do |day|
        break if day[:contributionCount].zero?

        streak += 1
      end
      streak
    end
  end
end
