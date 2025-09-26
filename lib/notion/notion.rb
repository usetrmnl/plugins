require 'unicode/emoji'

module Plugins
  class Notion < Base

    class << self
      %i[list_databases list_pages].each do |method|
        define_method(method) do |credentials|
          fetch_notion_data(credentials, method)
        end
      end

      %i[search_databases search_pages].each do |method|
        define_method(method) do |credentials, query = ""|
          fetch_notion_data(credentials, method, query)
        end
      end

      def fetch_notion_data(credentials, method_name, *)
        return [] unless credentials.dig('notion', 'access_token').presence

        ::APIClients::Notion.new(credentials.dig('notion', 'access_token')).send(method_name, *)
      rescue StandardError => e
        Rails.logger.error "Notion API error: #{e.message}"
        []
      end
    end

    def api_client
      @api_client ||= ::APIClients::Notion.new(access_token)
    end

    def locals
      return { error: "Missing integration token or resource ID" } if access_token.blank? || (notion_database_id.blank? && notion_page_id.blank?)

      common_locals = {
        multi_column_display: settings["multi_column_display"],
        image_height: image_height
      }

      case settings["display_type"]
      when "database"
        common_locals.merge(
          items: database_items,
          display_type: "database",
          status_field: settings["status_field"]&.strip,
          labeled_properties: settings["labeled_properties"]&.split(',')&.map(&:strip),
          listed_properties: settings["listed_properties"]&.split(',')&.map(&:strip)
        )
      when "page"
        common_locals.merge(
          items: page_content,
          display_type: "page"
        )
      else
        { error: "Invalid display type" }
      end
    rescue StandardError => e
      { error: e.message }
    end

    def notion_database_id
      value = settings["notion_database_id"]
      return nil if value.blank?

      # Extract ID from combined format "id::name"
      value.split('::').first
    end

    def notion_page_id
      value = settings["notion_page_id"]
      return nil if value.blank?

      # Extract ID from combined format "id::name"
      value.split('::').first
    end

    private

    def strip_emojis(text)
      return text unless text.is_a?(String)

      text.gsub(Unicode::Emoji::REGEX, '').strip
    end

    def extract_computed_value(computed_property)
      return nil unless computed_property.is_a?(Hash)

      property_type = computed_property["type"]
      case property_type
      when "string"
        computed_property["string"]
      when "number"
        computed_property["number"]
      when "boolean"
        computed_property["boolean"] ? "Yes" : "No"
      when "date"
        format_date(computed_property["date"]&.dig("start"))
      when "array"
        computed_property["array"]&.length&.to_s
      else
        computed_property[property_type] || computed_property.to_s
      end
    end

    def extract_files_value(files)
      return nil unless files.is_a?(Array)

      files.map { |file| file["name"] || extract_file_url(file) }.compact.join(", ")
    end

    def extract_file_url(file)
      case file["type"]
      when "external"
        file.dig("external", "url")
      when "file"
        file.dig("file", "url")
      end
    end

    def extract_relation_value(relation)
      return nil unless relation.is_a?(Array)

      "#{relation.length} related #{'item'.pluralize(relation.length)}"
    end

    def database_items
      return [] unless notion_database_id.present?

      data = fetch_database_data
      return [] unless data

      (data["results"] || []).map { |item| transform_database_item(item) }
    end

    def page_content
      return {} unless notion_page_id.present?

      page_data = fetch_page_data
      blocks_data = fetch_page_blocks
      return {} unless page_data && blocks_data

      {
        blocks: format_blocks(blocks_data["results"] || []),
        properties: extract_properties(page_data["properties"]),
        url: page_data["url"],
        last_edited: format_date(page_data["last_edited_time"])
      }
    end

    def fetch_database_data
      @database_data ||= begin
        filter = build_filter
        options = { page_size: max_items, sorts: build_sorts }
        options[:filter] = filter unless filter.nil?

        api_client.query_database(notion_database_id, **options)
      end
    end

    def fetch_page_data
      @page_data ||= api_client.get_page_info(notion_page_id)
    end

    def fetch_page_blocks
      @page_blocks ||= api_client.get_page_blocks(notion_page_id, page_size: max_items)
    end

    def build_sorts
      sort_property = settings["sort_property"]&.strip
      sort_direction = settings["sort_direction"]

      if sort_property.present?
        key = %w[created_time last_edited_time].include?(sort_property) ? "timestamp" : "property"
        [{ key => sort_property, "direction" => sort_direction }]
      else
        [{ "timestamp" => "last_edited_time", "direction" => "descending" }]
      end
    end

    def build_filter
      filter_json = settings["filter_json"]&.strip
      return nil if filter_json.blank?

      # Basic size limit
      raise "Filter too large (max 10KB)" if filter_json.bytesize > 10_000

      parsed_filter = JSON.parse(filter_json)
      raise "Filter must be a JSON object" unless parsed_filter.is_a?(Hash) && parsed_filter.present?

      # Allow users to use the top-level filter key or just the filter object directly
      if parsed_filter.key?("filter")
        parsed_filter["filter"]
      else
        parsed_filter
      end
    end

    def transform_database_item(item)
      {
        title: extract_title_from_properties(item["properties"]),
        properties: extract_properties(item["properties"]),
        url: item["url"],
        last_edited: format_date(item["last_edited_time"])
      }
    end

    def extract_properties(properties)
      return [] unless properties

      properties.map do |key, value|
        next unless value.is_a?(Hash)

        {
          name: key,
          type: value["type"],
          value: format_property_value(value),
          raw_value: value
        }
      end.compact
    end

    def format_property_value(property) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      type = property["type"]

      value = case type
              when "rich_text", "title"
                property[type].map { |text| text["plain_text"] }.join
              when "number"
                property["number"]
              when "select"
                property["select"]&.dig("name")
              when "multi_select"
                property["multi_select"]&.map { |option| option["name"] }&.join(", ")
              when "date"
                format_date(property["date"]&.dig("start"))
              when "checkbox"
                property["checkbox"] ? "Yes" : "No"
              when "url", "email", "phone_number"
                property[type]
              when "people"
                property["people"]&.map { |person| person["name"] }&.join(", ")
              when "formula", "rollup"
                extract_computed_value(property[type])
              when "created_by", "last_edited_by"
                property[type]&.dig("name") || property[type]&.dig("object")
              when "created_time", "last_edited_time"
                format_date(property[type])
              when "files"
                extract_files_value(property["files"])
              when "relation"
                extract_relation_value(property["relation"])
              when "status"
                property["status"]&.dig("name")
              else
                property["plain_text"] || property.to_s
              end

      # Only strip emojis from string values
      return value if value.is_a?(Numeric)

      strip_emojis(value.to_s)
    end

    def format_blocks(blocks)
      blocks.map do |block|
        block_type = block["type"]
        block_data = block[block_type] || {}

        {
          type: block_type,
          text: extract_block_text(block_data, block),
          checked: block_data["checked"],
          language: block_data["language"],
          image_url: extract_image_url(block),
          caption: extract_image_caption(block)
        }
      end
    end

    def extract_block_text(block_data, block)
      caption = block_data.dig("caption", 0, "text", "content").presence

      case block["type"]
      when "child_page"
        return strip_emojis(block_data["title"])
      when "bookmark", "embed"
        return strip_emojis([caption, block_data["url"]].compact.join(" - "))
      when "video"
        return strip_emojis([caption, block_data.dig("external", "url")].compact.join(" - ")) if block_data["external"]
      when "file"
        return strip_emojis([caption, block_data.dig("file", "name")].compact.join(" - ")) if block_data["file"]
      when "equation"
        return strip_emojis(block_data["expression"]) if block_data["expression"]
      end

      rich_text = block_data["rich_text"] || block_data["text"]
      return "" unless rich_text

      text = rich_text.map { |text| text["plain_text"] }.join
      strip_emojis([caption, text].compact.join(" - "))
    end

    def extract_image_url(block)
      return nil unless block["type"] == "image"

      image = block["image"]
      image&.dig("external", "url") || image&.dig("file", "url")
    end

    def extract_image_caption(block)
      return nil unless block["type"] == "image"

      caption = block.dig("image", "caption")&.map { |text| text["plain_text"] }&.join
      caption ? strip_emojis(caption) : nil
    end

    def extract_title_from_properties(properties)
      return "Untitled" unless properties&.any?

      # Try configured title field first, then fall back to first property
      title_field = settings["title_field"]&.strip
      property = properties[title_field] if title_field.present?
      property ||= properties.values.first

      return "Untitled" unless property

      title = format_property_value(property).presence || "Untitled"
      strip_emojis(title)
    end

    def format_date(date_string)
      return "" unless date_string

      Date.parse(date_string).strftime("%b %d, %Y")
    rescue StandardError
      date_string.to_s
    end

    def max_items = settings["max_items"].presence && settings["max_items"].to_i

    def image_height = settings["image_height"].presence && settings["image_height"].to_i
    def access_token = settings.dig("notion", "access_token")
  end
end
