require 'open-uri'

module Plugins
  class Screenshot < Base
    def locals
      { html_hex: Digest::SHA2.hexdigest(html_document) } # Adding to compare the hex of the HTML document
    end

    # rubocop:disable Security/Open, Lint/ShadowedException
    def html_document(*)
      @doc ||= begin
        raise InvalidURL if settings['url'].include?('localhost')

        document = Nokogiri::HTML(URI.open(url, request_specific_fields: headers, open_timeout: 5))

        %w[script img].each do |element|
          absolutize_element(document, element)
        end
        document.to_s.encode("UTF-8")
      end
    rescue Addressable::URI::InvalidURIError, OpenURI::HTTPError, Errno::ENOENT, Net::OpenTimeout, Socket::ResolutionError, SocketError, InvalidURL => e
      handle_erroring_state(e.message)
      erroring_html(e.message)
    end
    # rubocop:enable Security/Open, Lint/ShadowedException

    private

    def url
      @url ||= begin
        uri = URI.parse(settings['url'])
        response = Net::HTTP.get_response(uri, headers)
        response.is_a?(Net::HTTPRedirection) ? response['location'] : settings['url']
      end
    end

    def headers
      return {} unless settings['headers']

      string_to_hash(settings['headers'])
    end

    def erroring_html(message) = "<html><body><p>Error #{message}</p></html>"

    def absolutize_element(doc, element)
      doc.at(element)&.attribute_nodes&.each do |tag|
        tag.value = "#{url.chomp('/')}/#{tag.value}" unless tag.value.include?('http')
      end
    end
  end
end
