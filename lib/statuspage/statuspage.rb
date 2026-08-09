module Plugins
  class Statuspage < Base

    def locals
      { pages: }
    end

    private

    # NOTE: only works with pages hosted on statuspage.io
    def pages
      content = { 'incidents' => [], 'scheduled' => [] }
      items.each do |item|
        next unless item.is_a?(Hash) && item[:date]

        if item[:date] > DateTime.now
          item[:icon] = 'calendar_star'
          content['scheduled'] << item
        else
          item[:icon] = item[:date] > 24.hours.ago ? 'shield_warning' : 'hexagon'
          content['incidents'] << item
        end
      end

      content
    end

    # rubocop:disable Security/Open
    def items
      page_urls.map do |url|
        URI.open(url, open_timeout: 5) do |rss|
          feed = RSS::Parser.parse(rss, validate: false)
          latest_post = feed&.items&.first

          if latest_post.nil?
            {
              content: 'Unsupported status page',
              site_name: url
            }
          elsif latest_post.is_a?(RSS::Atom::Feed::Entry)
            {
              title: latest_post&.title&.content,
              date: latest_post&.published&.content,
              content: latest_post&.content&.content,
              site_name: feed&.title&.content
            }
          else
            {
              title: latest_post&.title,
              date: latest_post&.pubDate,
              content: latest_post&.description, # not used, just in case
              site_name: feed&.channel&.title&.split('Status')&.first&.squish # => 'Prompt.io'
            }
          end
        end
      rescue OpenURI::HTTPError, RSS::NotWellFormedError, Errno::ENOENT
        nil
      rescue URI::InvalidURIError, SocketError, Resolv::ResolvError, Net::OpenTimeout, Net::ReadTimeout,
             OpenSSL::SSL::SSLError, Errno::EHOSTUNREACH, Errno::ECONNREFUSED, Errno::EPIPE => e
        handle_erroring_state(e.message)
        nil
      rescue RuntimeError => e
        raise unless e.message.include?('redirection forbidden')

        handle_erroring_state(e.message)
        nil
      end.compact
    end
    # rubocop:enable Security/Open

    def page_urls
      line_separated_string_to_array(settings['page_urls']).map do |base_url|
        next unless base_url.include?('http') # IDEA: extract RssFeed > validate_uri()

        if ['/history.rss', '/feed'].any? { |pattern| base_url.include?(pattern) }
          base_url
        else
          base_url.chomp('/').concat('/history.rss')
        end
      end.compact # ignores skipped / malformed URLs
    end
  end
end
