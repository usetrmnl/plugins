module Plugins
  class HackerNews < Base

    STORY_COUNT = 14.freeze

    STORY_TYPES = {
      'top_stories' => 'topstories',
      'show_hn' => 'showstories'
    }.freeze

    STORY_LABEL = {
      'top_stories' => 'Top Stories',
      'show_hn' => 'Show HN'
    }.freeze

    def locals
      { stories:, category: }
    end

    private

    def stories
      fetch_stories[..STORY_COUNT].map do |story_id|
        story = fetch_item(story_id)
        {
          title: story['title'].gsub(/show hn: /i, ''),
          score: story['score'],
          by: story['by']
        }
      end
    end

    def fetch_stories = HTTParty.get("https://hacker-news.firebaseio.com/v0/#{story_type}.json", headers:)

    def fetch_item(story_id) = HTTParty.get("https://hacker-news.firebaseio.com/v0/item/#{story_id}.json", headers:)

    # https://github.com/HackerNews/API?tab=readme-ov-file#ask-show-and-job-stories
    def story_type
      STORY_TYPES[settings['story_type']]
    end

    def category
      STORY_LABEL[settings['story_type']]
    end

    def headers
      { 'content-type' => 'application/json' }
    end
  end
end
