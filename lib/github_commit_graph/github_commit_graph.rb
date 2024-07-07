module Plugins
  class GithubCommitGraph < Base
    def locals
      { username:, contributions: }
    end

    private

    def username = settings['username']

    def contributions
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
      body = {
        query: query,
        variables: { userName: settings['username'] }
      }

      url = 'https://api.github.com/graphql'
      resp = HTTParty.post(url, body: body.to_json, headers: headers)
      data = resp.dig('data', 'user', 'contributionsCollection', 'contributionCalendar')

      { total: data['totalContributions'], commits: data['weeks'] }
    end

    def headers
      { 'authorization' => "Bearer #{Rails.application.credentials.plugins.github_commit_graph_token}" }
    end
  end
end
