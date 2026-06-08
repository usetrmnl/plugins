module Plugins
  class RssFeed < Base

    def locals
      { rss_feed: }
    end

    private

    def rss_feed
      feed = process_feed
      feed.is_a?(Array) ? feed : [feed]
    end

    def process_feed
      validate_uri(settings['url'])
      response = fetch(settings['url'].strip, headers:)

      raise InvalidURL unless response.respond_to?(:code) && response.respond_to?(:body)
      raise InvalidURL if response.code.to_i >= 400
      return content_error(StandardError.new("Response Code: #{response.code}")) if response.code != 200
      return content_error(StandardError.new("No Content")) if response.body.nil? || response.body.empty?

      feed = RSS::Parser.parse(response.body, validate: false)

      if layout == 'featured'
        normalize_feed(feed&.items&.first)
      elsif layout == 'list'
        feed&.items&.[](0..7)&.map do |post|
          normalize_feed(post, strip_to_text: true)
        end
      end
    rescue OpenURI::HTTPError, RSS::NotWellFormedError, RSS::TooMuchTagError => e
      content_error(e)
    rescue InvalidURL, URI::InvalidURIError, OpenSSL::SSL::SSLError => e
      handle_erroring_state(e)
      content_error(e)
    end

    def normalize_feed(post, strip_to_text: false)
      content = if post.is_a?(RSS::Atom::Feed::Entry)
                  {
                    title: post&.title&.content,
                    content: post&.summary&.content || post&.content&.to_s
                  }.compact
                else
                  {
                    title: post&.title,
                    content: post&.content_encoded || post&.description
                  }.compact
                end
      return content_error(StandardError.new("No Content")) if content.empty?

      if strip_to_text
        strip_html(content)
      else
        dither_image(content)
      end
    end

    def validate_uri(url)
      raise InvalidURL unless url =~ URI::DEFAULT_PARSER.make_regexp
    end

    # added 2025-01-08 per customer observation that some rss feeds prevent fetches without user-agent present
    def headers
      {
        'user-agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_2) AppleWebKit/601.3.9 (KHTML, like Gecko) Version/9.0.2 Safari/601.3.9'
      }
    end

    def dither_image(feed)
      content = feed[:content]
      return feed if content.nil?

      content.gsub!(%r{<img(.*?)/?>}, '<img\1 class="image-dither w-full h-auto object-contain block mx-auto" />')
      feed[:content] = content
      feed
    end

    # Make content in the list view plaintext so we don't overflow.
    def strip_html(feed)
      content = feed[:content]
      return feed if content.nil?

      plain_text = ActionController::Base.helpers.strip_tags(content)
      feed[:content] = plain_text.squish.truncate(200)
      feed
    end

    def content_error(error)
      {
        title: 'Error while parsing RSS content',
        content: "Message: #{error&.message}"
      }
    end

    def layout = settings['layout'] || 'featured'
  end
end
