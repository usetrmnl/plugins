module Plugins
  class NanoBananaDashboard < Base
    GEMINI_URL = 'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent'.freeze

    GEMINI_MODELS = {
      'flash' => 'gemini-2.5-flash-image',
      'pro' => 'gemini-3-pro-image-preview'
    }.freeze

    VALID_ASPECT_RATIOS = %w[16:9 9:16 4:3 3:4 3:2 2:3 1:1 21:9].freeze

    # NOTE: Scenes define how data is physically integrated into an environment.
    # Data should be prominent and legible, but exist as natural objects within the scene.
    # The 'none' key skips scene framing — relies only on user style additions.
    SCENE_PROMPTS = {
      'none' => nil,

      'scenic landscape' => 'A natural landscape (mountains, coastline, or countryside) where data exists as ' \
                            'objects in the world — temperatures on wooden trail signs, numbers carved into stone markers, ' \
                            'text on banners strung between trees, weather shown in the sky itself.',

      'daily briefing' => 'A newspaper front page or cork bulletin board where data fills the headlines, ' \
                          'columns, and pinned notes. Each data source is its own article or pinned card with a bold header.',

      'retro comic' => 'A comic book page where data lives inside speech bubbles, bold captions, and screens ' \
                       'within panels. Characters hold up signs or react to the numbers. Halftone shading throughout.',

      'technical blueprint' => 'An engineering schematic on grid paper where data appears as precise measurements, ' \
                               'gauge readouts, and specification callouts connected by leader lines to diagrams.',

      'vintage poster' => 'A 1930s art deco poster where data is the typography — big bold headline numbers, ' \
                          'values in ribbon banners, stats in ornamental frames with decorative flourishes between them.',

      'cozy cafe' => 'A coffee shop chalkboard where data is written in chalk — temperatures on a menu board, ' \
                     'numbers on table tent signs, schedules on a wall clock, stats in chalk-drawn frames.',

      'space mission' => 'A mission control room where data lives on glowing monitor screens, instrument panels, ' \
                         'HUD readouts, and orbital trajectory displays. Numbers on gauges and digital readout screens.',

      'japanese ink' => 'A sumi-e ink wash scene where data is painted in elegant brush calligraphy on hanging ' \
                        'scroll panels, carved into stone lanterns, and written on paper fans and wooden plaques.',

      'library study' => 'A library desk where data appears on open book pages, handwritten note cards, ' \
                         'a desk calendar, spines of books, and a wall clock. Pinned index cards on a cork board.',

      'steampunk workshop' => 'A Victorian workshop where data lives on brass pressure gauges, analog dial faces, ' \
                              'mechanical ticker tape readouts, etched metal plates, and clockwork number wheels.',

      'ocean depths' => 'An underwater scene where data is etched on treasure chest plates, written inside ' \
                        'message bottles, displayed on diver slate boards, and formed by bioluminescent creatures.',

      'minimalist grid' => 'A clean grid layout where data sits in precise typographic blocks separated by thin ' \
                           'rules and geometric shapes. Numbers in bold sans-serif, generous white space between sections.'
    }.freeze

    def process!
      @generate_screen = api_key.present? && !use_cache?
      super
    end

    def locals
      return { errors: "Gemini API key is required. Get one at aistudio.google.com" } if api_key.blank?
      return cached_result if use_cache?

      generate_scene
    rescue StandardError => e
      handle_error(e)
    end

    private

    # NOTE: Overrides base class to skip screen pipeline when cached or missing API key.
    # Base class checks merge variables; this checks cache state instead.
    def skip_screen_generation?
      !@generate_screen
    end

    # --- Caching ---

    def use_cache?
      !force_refresh? && prompt_unchanged? && cached_image_url.present?
    end

    def cached_image_url
      plugin_setting.persistence_data.dig('locals', 'image_url')
    end

    def cached_prompt_hash
      plugin_setting.persistence_data.dig('locals', 'prompt_hash')
    end

    def prompt_unchanged?
      cached_prompt_hash == current_prompt_hash
    end

    def current_prompt_hash
      Digest::SHA256.hexdigest(cache_key_inputs)
    end

    def cache_key_inputs
      [
        settings.slice(
          'style_prompt', 'style_custom', 'custom_text',
          'data_instructions', 'aspect_ratio', 'model', 'color_palette'
        ).sort.to_json,
        selected_plugin_ids.sort.to_s,
        source_data_fingerprint
      ].join(':')
    end

    def source_data_fingerprint
      return '' if selected_plugin_ids.empty?

      Digest::SHA256.hexdigest(selected_plugins_data.to_json)
    end

    def cached_result
      { image_url: cached_image_url, prompt_hash: cached_prompt_hash }
    end

    # --- Plugin Data ---

    # CONTEXT: Settings store plugin references as "keyname_id" (e.g. "weather_42").
    # We extract the numeric ID to query plugin_settings by primary key.
    def selected_plugin_ids
      @_selected_plugin_ids ||= [settings['plugin_1'], settings['plugin_2'], settings['plugin_3']]
                                .compact
                                .reject(&:blank?)
                                .map { |s| s.split('_').last.to_i }
                                .select(&:positive?)
                                .uniq
    end

    # NOTE: Delegates to User#merged_plugin_locals which handles webhook freshness
    # (preferring api['merge_variables'] over stale locals for webhook plugins).
    def selected_plugins_data
      return {} if selected_plugin_ids.empty?

      @_selected_plugin_data ||= user.merged_plugin_locals(plugin_setting_ids: selected_plugin_ids)
    end

    # --- Image Generation ---

    def generate_scene
      {
        image_url: call_gemini_api(build_prompt(selected_plugins_data)),
        prompt_hash: current_prompt_hash
      }
    end

    def build_prompt(data)
      <<~PROMPT
        Generate a single image for an e-ink display in #{orientation} orientation where data is naturally integrated into the scene.

        The data is the reason this image exists — it must be prominent, legible, and accurate. But it should feel like it belongs in the world, not pasted on top.

        #{scene_section}
        Available data — each key is a data source name:
        #{data.to_json}

        Data instructions:
        #{data_instructions_text}
        #{custom_text_section}
        How to integrate data:
        - Data should appear as physical objects in the scene (signs, displays, labels, etc.)
        - Use LARGE, bold text for key values — legibility is the top priority
        - Pair graphical representations with their numeric values
        - Most important data should be largest and most central
        - Group related data together

        Requirements:
        - #{palette_prompt_section}
        - Optimized for e-ink display
        - High contrast with sharp edges — no gradients or soft shadows
        - All text, numbers, and data must be clearly legible even at small display sizes
        - Compose for #{orientation} #{aspect_ratio} aspect ratio
      PROMPT
    end

    # --- Gemini API ---

    def call_gemini_api(prompt)
      parsed = gemini_request(gemini_url, gemini_body(prompt))
      image_part = parsed.dig('candidates', 0, 'content', 'parts')
                         &.find { |p| p['inlineData'] }
      raise StandardError, "No image data in response" unless image_part

      upload_to_storage(image_part.dig('inlineData', 'data'), image_part.dig('inlineData', 'mimeType'))
    end

    # NOTE: Retries once on timeout using recursion to avoid mutable counter state.
    def gemini_request(url, body, retried: false)
      response = HTTParty.post(url, body: body, headers: gemini_headers, timeout: 60)
      parsed = response.parsed_response
      raise StandardError, "Empty response from Gemini API" if parsed.nil?
      raise StandardError, parsed.dig('error', 'message') || 'Unknown API error' if parsed['error']

      parsed
    rescue Net::ReadTimeout, Net::OpenTimeout
      raise if retried

      sleep 1
      gemini_request(url, body, retried: true)
    end

    # NOTE: Reuses existing blob when possible to avoid orphaned blobs in storage.
    # New attachments need filename/content_type; existing blobs just need the bytes replaced.
    def upload_to_storage(base64_data, mime_type)
      binary = Base64.decode64(base64_data)

      if plugin_setting.temp_image.attached?
        plugin_setting.temp_image.blob.upload(StringIO.new(binary), identify: true)
        plugin_setting.temp_image.blob.save!
      else
        plugin_setting.temp_image.attach(
          io: StringIO.new(binary),
          filename: "nano-banana-#{plugin_setting.id}.#{mime_type.split('/').last}",
          content_type: mime_type
        )
      end

      Rails.application.routes.url_helpers.url_for(plugin_setting.temp_image)
    end

    def gemini_url
      format(GEMINI_URL, gemini_model)
    end

    def gemini_headers
      {
        "Content-Type" => "application/json",
        "x-goog-api-key" => api_key
      }
    end

    def gemini_body(prompt)
      {
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          imageConfig: { aspectRatio: aspect_ratio }
        }
      }.to_json
    end

    # --- Error Handling ---

    def handle_error(error)
      logger.error { "NanoBananaDashboard error: #{error.message}" }

      if cached_image_url.present?
        cached_result
      else
        { errors: user_friendly_error(error) }
      end
    end

    def user_friendly_error(error)
      case error.message
      when /API_KEY_INVALID/i, /invalid.*key/i then "Invalid API key. Check your Gemini settings."
      when /RATE_LIMIT_EXCEEDED/i, /rate_limit/i then "API rate limit exceeded. Try again later."
      when /SAFETY/i, /content_policy/i then "Could not generate due to content policy."
      when /billing/i then "Gemini billing issue. Check your account."
      when /No image data/i then "No image was generated. Try a different prompt."
      else "Image generation failed. Please try again."
      end
    end

    # --- Settings ---

    def api_key = settings['api_key']

    def gemini_model = GEMINI_MODELS[settings['model']] || GEMINI_MODELS['flash']

    def scene_prompt_text
      style = settings['style_prompt']
      return SCENE_PROMPTS.except('none').values.compact.sample if style == 'random'

      SCENE_PROMPTS[style] || SCENE_PROMPTS['none']
    end

    def scene_section
      parts = [
        ("Scene: #{scene_prompt_text}" if scene_prompt_text),
        ("Additional style: #{settings['style_custom']}" if settings['style_custom'].present?)
      ].compact

      parts.any? ? "#{parts.join("\n")}\n" : ''
    end

    def custom_text_section
      text = settings['custom_text']
      return '' unless text.present?

      "\nCustom text to display prominently in the scene: \"#{text}\"\n"
    end

    def data_instructions_text
      return "Data usage instructions: #{settings['data_instructions']}" if settings['data_instructions'].present?

      'Feature the most important data points prominently. Use your judgment on what to emphasize.'
    end

    # --- Color Palette ---

    def palette_id = settings['color_palette'].presence || 'bw'

    # CONTEXT: Returns hex array for constrained palettes, nil for wide-spectrum
    # (gray-256, color-12bit, color-24bit) where listing colors is meaningless.
    def palette_hex_colors
      palette = Screen::Palette.find(palette_id)
      return palette.colors if palette.color? && palette.colors.present?

      grayscale_hex_values(palette.grays) if palette.grayscale? && palette.grays <= 16
    rescue ArgumentError
      grayscale_hex_values(2)
    end

    # NOTE: Matches ImageMagick posterize — evenly spaced gray levels.
    def grayscale_hex_values(count)
      # rubocop:disable Style/FormatStringToken
      (0...count).map { |i| format('#%02X%02X%02X', *([(i * 255.0 / (count - 1)).round] * 3)) }
      # rubocop:enable Style/FormatStringToken
    end

    def palette_prompt_section
      colors = palette_hex_colors
      return "Use ONLY these exact colors (no others): #{colors.join(', ')}" if colors
      return 'Full grayscale spectrum' if palette_id.start_with?('gray')

      'Full color spectrum'
    end

    # --- Aspect Ratio & Orientation ---

    def aspect_ratio
      ratio = settings['aspect_ratio']
      VALID_ASPECT_RATIOS.include?(ratio) ? ratio : '16:9'
    end

    def orientation
      w, h = aspect_ratio.split(':').map(&:to_i)
      return 'landscape' if w > h
      return 'portrait' if h > w

      'square'
    end
  end
end
