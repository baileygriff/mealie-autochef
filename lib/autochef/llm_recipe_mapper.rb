# frozen_string_literal: true

require 'json'
require 'httparty'
require_relative 'models/product_map'

module Autochef
  # Suggests Food Lion search terms, quantities, and pantry-skip flags for
  # unmapped Mealie shopping list ingredients using Claude Haiku.
  #
  # Usage:
  #   mapper = LlmRecipeMapper.new(cfg)
  #   result = mapper.map_unmapped(mealie_client: client, plan_history: history)
  #
  # Result fields:
  #   new_mapped     — Array of {key:, search_term:, qty:, unit:} saved to product_map
  #   pantry_skipped — Array of ingredient name strings marked __skip__
  #   suspicious     — Array of {ingredient_name:, concern:} for flagged existing mappings
  #   errors         — Array of error strings (LLM failures, save failures)
  class LlmRecipeMapper
    ANTHROPIC_API_URL     = 'https://api.anthropic.com/v1/messages'
    ANTHROPIC_API_VERSION = '2023-06-01'
    HAIKU_MODEL           = 'claude-haiku-4-5-20251001'

    Result = Struct.new(:new_mapped, :pantry_skipped, :suspicious, :errors, keyword_init: true)

    def initialize(cfg)
      @cfg = cfg
    end

    # Fetches unmapped ingredients from the Mealie "Next Order" shopping list,
    # calls Claude Haiku for suggestions, saves them to product_map, and runs
    # a flagging pass on existing mappings that look suspicious.
    # Returns a Result struct.
    def map_unmapped(mealie_client:, plan_history: nil)
      unless @cfg.llm.enabled
        return Result.new(
          new_mapped: [], pantry_skipped: [], suspicious: [],
          errors: ['LLM not enabled — set llm.enabled: true in config.yaml']
        )
      end

      list_name   = @cfg.mealie.next_order_list
      list        = mealie_client.find_or_create_shopping_list(list_name)
      list_detail = mealie_client.shopping_list(list['id'])
      raw_items   = list_detail['listItems'] || list_detail['items'] || []

      autochef_items = raw_items.select do |item|
        (item['extras'] || {})['autochef_managed'].to_s == 'true'
      end

      if autochef_items.empty?
        return Result.new(
          new_mapped: [], pantry_skipped: [], suspicious: [],
          errors: ["No autochef-managed items in \"#{list_name}\". Run `main.rb shop` first."]
        )
      end

      existing_keys = Models::ProductMap.pluck(:key).to_set
      unmapped      = autochef_items.reject { |item| existing_keys.include?(normalize(item['note'])) }
      mapped_items  = autochef_items.select { |item| existing_keys.include?(normalize(item['note'])) }

      plan_recipes = plan_history ? plan_history.plan.values.map { |e| e['recipe_name'].to_s }.uniq : []

      new_mapped     = []
      pantry_skipped = []
      errors         = []

      if unmapped.any?
        begin
          suggestions = call_mapping_llm(unmapped, plan_recipes)
          suggestions.each do |s|
            key = normalize(s['ingredient_name'])
            next if key.empty?

            record = Models::ProductMap.find_or_initialize_by(key: key)
            if s['pantry_skip']
              record.search_term = '__skip__'
              record.default_qty = 1
              record.rounding    = 'up'
              record.save!
              pantry_skipped << key
            else
              record.search_term = s['search_term'].to_s.strip.empty? ? key : s['search_term'].to_s.strip
              record.default_qty = [s['qty'].to_i, 1].max
              record.pack_unit   = s['unit'].to_s.strip.empty? ? nil : s['unit'].to_s.strip
              record.rounding    = 'up'
              record.save!
              new_mapped << { key: key, search_term: record.search_term,
                              qty: record.default_qty, unit: record.pack_unit }
            end
          rescue ActiveRecord::RecordInvalid => e
            errors << "Failed to save #{key.inspect}: #{e.message}"
          end
        rescue StandardError => e
          errors << "LLM mapping call failed: #{e.class}: #{e.message}"
        end
      end

      suspicious = []
      if mapped_items.any?
        begin
          existing_entries = mapped_items.filter_map do |item|
            key = normalize(item['note'])
            pm  = Models::ProductMap.find_by(key: key)
            next unless pm

            {
              'ingredient_name' => key,
              'search_term'     => pm.search_term,
              'qty'             => pm.default_qty,
              'unit'            => pm.pack_unit,
              'pantry_skip'     => pm.search_term == '__skip__'
            }
          end

          suspicious = call_flagging_llm(existing_entries, plan_recipes) if existing_entries.any?
        rescue StandardError => e
          errors << "LLM flagging pass failed: #{e.class}: #{e.message}"
        end
      end

      Result.new(new_mapped: new_mapped, pantry_skipped: pantry_skipped,
                 suspicious: suspicious, errors: errors)
    end

    private

    def normalize(name)
      name.to_s.downcase.strip.gsub(/\s+/, ' ')
    end

    # Batch-maps all unmapped ingredients in a single Haiku call.
    def call_mapping_llm(items, plan_recipes)
      recipe_ctx = plan_recipes.any? ? "Recipes this week: #{plan_recipes.join(', ')}." : ''

      items_lines = items.map do |item|
        note     = item['note'].to_s.strip
        qty_str  = item['quantity'].to_s.strip
        unit_str = (item.dig('unit', 'name') || item['unit'].to_s).to_s.strip
        parts    = [note, qty_str.empty? ? nil : qty_str, unit_str.empty? ? nil : unit_str].compact
        "- #{parts.join(' ')}"
      end.join("\n")

      user_msg = <<~USER
        I'm building a Food Lion To Go grocery cart from a weekly meal plan.
        #{recipe_ctx}

        The following ingredients from my Mealie shopping list have no Food Lion product mapping yet.
        For each ingredient, suggest:
          - search_term: what to search on Food Lion (common product name, brand-agnostic)
          - qty: how many packs/units to buy (integer >= 1)
          - unit: the pack unit (ea, lb, oz, ct, carton, bag, bunch, etc.) or null
          - pantry_skip: true if this is a pantry staple most households already have, false otherwise

        Pantry staples to auto-skip: salt, pepper, black pepper, olive oil, vegetable oil, canola oil,
        garlic powder, onion powder, paprika, cumin, chili powder, cayenne, oregano, thyme, basil,
        bay leaves, red pepper flakes, soy sauce, fish sauce, hot sauce, Worcestershire sauce,
        vinegar (any type), sugar, brown sugar, flour, cornstarch, baking soda, baking powder,
        vanilla extract, dried herbs (any), chicken bouillon, beef bouillon, cooking spray.

        Unmapped ingredients:
        #{items_lines}

        Rules:
        - For real grocery items use a simple, clear search term (e.g. "chicken breast" not "boneless skinless chicken breast fillets")
        - qty should be 1 for most items; only increase when the recipe clearly needs multiple units
        - Use "lb" for proteins sold by weight, "ea" or "ct" for single items, "bag" or "bunch" for produce

        Return ONLY a JSON array, no prose, no markdown fences:
        [{"ingredient_name": "...", "search_term": "...", "qty": N, "unit": "..." or null, "pantry_skip": true or false}]

        Include ALL ingredients from the input list above.
      USER

      raw = call_claude(user_msg)
      parse_json_array(raw)
    end

    # Asks Haiku to flag any suspicious existing mappings. Returns [] on any error.
    def call_flagging_llm(existing_entries, plan_recipes)
      recipe_ctx = plan_recipes.any? ? "Recipes this week: #{plan_recipes.join(', ')}." : ''

      entries_lines = existing_entries.map do |e|
        if e['pantry_skip']
          "- #{e['ingredient_name']}: pantry-skip"
        else
          unit_str = e['unit'].to_s.strip.empty? ? '' : " #{e['unit']}"
          "- #{e['ingredient_name']}: search=\"#{e['search_term']}\" qty=#{e['qty']}#{unit_str}"
        end
      end.join("\n")

      user_msg = <<~USER
        I have existing Food Lion product mappings for a weekly meal plan.
        #{recipe_ctx}

        Please review these mappings and flag any that look suspicious:
        - qty too high or too low for a typical household grocery pack
        - search_term too generic (e.g. "sauce" when "soy sauce" is better)
        - pantry_skip on something that should actually be purchased
        - search_term that seems like the wrong product for the ingredient

        Existing mappings:
        #{entries_lines}

        Return ONLY a JSON array of flagged items, no prose, no markdown fences.
        If nothing looks suspicious, return an empty array: []
        [{"ingredient_name": "...", "concern": "one sentence explaining the issue"}]
      USER

      raw = call_claude(user_msg)
      parse_json_array(raw)
    rescue StandardError
      []
    end

    def call_claude(user_msg)
      resp = HTTParty.post(
        ANTHROPIC_API_URL,
        headers: {
          'x-api-key'         => @cfg.llm.api_key,
          'anthropic-version' => ANTHROPIC_API_VERSION,
          'content-type'      => 'application/json'
        },
        body: {
          model:      HAIKU_MODEL,
          max_tokens: 2048,
          messages:   [{ role: 'user', content: user_msg }]
        }.to_json,
        open_timeout: 10,
        read_timeout: 60
      )

      raise "Anthropic API HTTP #{resp.code}: #{resp.body.to_s.slice(0, 300)}" unless resp.success?

      data = resp.parsed_response
      data.dig('content', 0, 'text') or raise 'Unexpected Anthropic response shape'
    end

    def parse_json_array(raw_text)
      clean  = raw_text.strip.gsub(/\A```(?:json)?\s*\n?/, '').gsub(/\n?```\s*\z/, '')
      parsed = JSON.parse(clean)
      raise "expected JSON array, got #{parsed.class}" unless parsed.is_a?(Array)

      parsed
    end
  end
end
