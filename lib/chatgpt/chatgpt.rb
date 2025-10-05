module Plugins
  class Chatgpt < Base

    def locals = { answer: }

    private

    def answer
      response = post(url, body:, headers:)
      return response.dig('error', 'message') if response.dig('error', 'message').present?

      content = response.dig('choices', 0, 'message', 'content').to_s

      return content unless web_search_enabled?

      annotations = response.dig('choices', 0, 'message', 'annotations') || []

      return content if annotations.empty? || content.empty?

      format_web_search_content(content, annotations)
    end

    def format_web_search_content(content, annotations)
      url_citations = extract_url_citations(annotations)
      return content if url_citations.empty?

      references = build_reference_map(url_citations)
      formatted_content = replace_citations_with_references(content, url_citations, references)
      append_references_section(formatted_content, references)
    end

    def extract_url_citations(annotations)
      annotations.select { |annotation| annotation['type'] == 'url_citation' }
    end

    def build_reference_map(url_citations)
      canonical_url_to_ref_num = {}
      references = {}
      next_ref_number = 1

      url_citations.each do |citation|
        url_info = citation['url_citation']
        title = url_info['title']
        url = url_info['url']
        canonical_url = normalize_url(url)

        next if canonical_url_to_ref_num[canonical_url]

        canonical_url_to_ref_num[canonical_url] = next_ref_number
        references[next_ref_number] = { title: title, url: url }
        next_ref_number += 1
      end

      { mapping: canonical_url_to_ref_num, references: references }
    end

    def replace_citations_with_references(content, url_citations, ref_data)
      formatted_content = content.dup
      canonical_url_to_ref_num = ref_data[:mapping]

      url_citations.each do |citation|
        url_info = citation['url_citation']
        url = url_info['url']
        canonical_url = normalize_url(url)
        ref_num = canonical_url_to_ref_num[canonical_url]

        domain = extract_domain(url)
        escaped_url = Regexp.escape(url)
        citation_pattern = /\(\[#{Regexp.escape(domain)}\]\(#{escaped_url}\)\)/

        if formatted_content.match(citation_pattern)
          formatted_content.sub!(citation_pattern, "[#{ref_num}]")
        end
      end

      formatted_content
    end

    def append_references_section(content, ref_data)
      references = ref_data[:references]
      return content if references.empty?

      reference_lines = references.map { |num, ref| "[#{num}] #{extract_domain_and_path(ref[:url])}" }
      "#{content}\n\n___\n\nReferences:\n#{reference_lines.join("\n")}"
    end

    def parse_url_safely(url)
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end

    def extract_domain(url)
      uri = parse_url_safely(url)
      return url unless uri

      uri.host.gsub('www.', '')
    end

    def extract_domain_and_path(url)
      uri = parse_url_safely(url)
      return url unless uri

      domain = uri.host.gsub('www.', '')
      path = uri.path == '/' ? '' : uri.path
      "#{domain}#{path}"
    end

    def normalize_url(url)
      uri = parse_url_safely(url)
      return url unless uri

      normalized_host = uri.host.gsub('www.', '')
      query_string = uri.query ? "?#{uri.query}" : ''
      "https://#{normalized_host}#{uri.path}#{query_string}"
    end

    def url = 'https://api.openai.com/v1/chat/completions'

    def headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{api_key}"
      }
    end

    def body
      {
        model: effective_model,
        messages: [
          {
            role: "system",
            content: "You are an imaginative and curious storyteller who uncovers rare and surprising ideas from science, technology, math, finance and art. Avoid repeating topics. Your responses should always include something unexpected or underappreciated. If the user query is not a fact, always give a random response to avoid giving the same response."
          },
          {
            role: "user",
            content: "Who won the Chess World Cup 2023?"
          },
          {
            role: "assistant",
            content: "Magnus Carlsen won the World Series in 2023."
          },
          {
            role: "user",
            content: prompt
          }
        ],
        temperature: web_search_enabled? ? nil : temperature
      }.compact.to_json
    end

    def prompt = settings['prompt']

    def api_key = settings['api_key']

    def model_name = settings['model'] || 'gpt-4o'

    def web_search_enabled? = settings['web_search'] == 'true'

    def effective_model
      return model_name unless web_search_enabled? || model_name.include?('search-preview')

      model_name == 'gpt-4o-search-preview' ? 'gpt-4o-search-preview' : 'gpt-4o-mini-search-preview'
    end

    def temperature
      {
        'gpt-4o' => 1.1,
        'gpt-4o-mini' => 1.0,
        'gpt-4.5' => 1.0,
        'gpt-4.1' => 0.95,
        'gpt-3.5-turbo' => 1.0,
        'o3' => 1.1,
        'o3-mini' => 1.0,
        'o3-mini-high' => 1.0,
        'o4-mini' => 1.0
      }[model_name]
    end
  end
end
