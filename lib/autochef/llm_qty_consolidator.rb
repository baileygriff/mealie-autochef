# frozen_string_literal: true

require 'json'
require 'httparty'

module Autochef
  # Post-resolve pass: sends the consolidated cart_items list to Claude Haiku
  # and asks it to rationalize quantities for real-world grocery pack sizes.
  #
  # Enhancement 2 on top of Enhancement 1 (which only deduplicates by exact
  # search_term). This layer catches cases like:
  #   - 2x "lemon" from two recipes → probably still just 1 lemon
  #   - 5 garlic cloves → 1 head of garlic
  #   - 3 cups chicken broth → 1 box (32 oz)
  #
  # Input:  Array of cart_item hashes with 'search_term', 'default_qty', 'pack_unit',
  #         and optional 'sources' (array of contributing ingredient names).
  # Output: Same array with 'default_qty' potentially adjusted. Unchanged items
  #         are returned as-is.
  class LlmQtyConsolidator
    ANTHROPIC_API_URL     = 'https://api.anthropic.com/v1/messages'
    ANTHROPIC_API_VERSION = '2023-06-01'
    HAIKU_MODEL           = 'claude-haiku-4-5-20251001'

    def initialize(cfg)
      @cfg = cfg
    end

    # Returns updated cart_items Array. Logs any adjustments to stdout.
    # Falls back to original cart_items on any error.
    def consolidate(cart_items, plan_recipes: [])
      return cart_items unless @cfg.llm.enabled

      prompt = build_prompt(cart_items, plan_recipes)
      raw    = call_claude(prompt)
      apply_adjustments(cart_items, parse_response(raw))
    rescue StandardError => e
      warn "LlmQtyConsolidator: #{e.class}: #{e.message} — using original quantities"
      cart_items
    end

    private

    def build_prompt(cart_items, plan_recipes)
      recipe_context = plan_recipes.any? ? plan_recipes.join(', ') : 'not specified'

      items_lines = cart_items.map do |item|
        sources = Array(item['sources']).reject(&:empty?)
        src_str = sources.any? ? " (from: #{sources.join(', ')})" : ''
        unit_str = item['pack_unit'].to_s.empty? ? '' : " #{item['pack_unit']}"
        "- \"#{item['search_term']}\": #{item['default_qty']}#{unit_str}#{src_str}"
      end.join("\n")

      user_msg = <<~USER
        I'm building a grocery cart for a weekly meal plan.

        Recipes this week: #{recipe_context}

        Resolved cart items (quantities already summed across recipes):
        #{items_lines}

        For each item, rationalize the quantity to a real-world grocery pack size.
        Examples:
          - 2 lemons → still just 1 bag/bunch (5ct is typical; 2 fit easily)
          - 5 garlic cloves → 1 head of garlic
          - 3 cups chicken broth → 1 carton (32 oz / ~4 cups)
          - 2 lbs ground beef → keep at 2 (sold by the pound)
          - 1 cup heavy cream → 1 (sold in half-pint or pint containers)

        Only adjust when it makes sense for common grocery pack sizes.
        If the current quantity is already reasonable, return it unchanged.

        Return ONLY a JSON array — no prose, no markdown fences:
        [{"search_term": "...", "default_qty": N, "reason": "..."}]

        Include ALL items from the input. For unchanged items, omit "reason".
      USER

      { user: user_msg }
    end

    def call_claude(prompt)
      resp = HTTParty.post(
        ANTHROPIC_API_URL,
        headers: {
          'x-api-key'         => @cfg.llm.api_key,
          'anthropic-version' => ANTHROPIC_API_VERSION,
          'content-type'      => 'application/json'
        },
        body: {
          model:      HAIKU_MODEL,
          max_tokens: 1024,
          messages:   [{ role: 'user', content: prompt[:user] }]
        }.to_json,
        open_timeout: 10,
        read_timeout: 30
      )

      raise "Anthropic API HTTP #{resp.code}: #{resp.body.to_s.slice(0, 300)}" unless resp.success?

      data = resp.parsed_response
      data.dig('content', 0, 'text') or raise 'Unexpected Anthropic response shape'
    end

    def parse_response(raw_text)
      clean  = raw_text.strip.gsub(/\A```(?:json)?\s*\n?/, '').gsub(/\n?```\s*\z/, '')
      parsed = JSON.parse(clean)
      raise "expected JSON array" unless parsed.is_a?(Array)

      parsed.each_with_object({}) do |entry, map|
        term = entry['search_term'].to_s
        next if term.empty?

        map[term] = { qty: entry['default_qty'].to_i, reason: entry['reason'].to_s }
      end
    end

    def apply_adjustments(cart_items, adjustments)
      adjusted_count = 0

      result = cart_items.map do |item|
        adj = adjustments[item['search_term']]
        next item unless adj

        new_qty = [adj[:qty], 1].max
        old_qty = (item['default_qty'] || 1).to_i

        if new_qty != old_qty
          adjusted_count += 1
          reason_str = adj[:reason].empty? ? '' : " — #{adj[:reason]}"
          puts "  LLM qty: #{item['search_term'].inspect} #{old_qty} → #{new_qty}#{reason_str}"
          item.merge('default_qty' => new_qty)
        else
          item
        end
      end

      puts "LLM quantity consolidation: #{adjusted_count} adjustment(s)" if adjusted_count.positive?
      result
    end
  end
end
