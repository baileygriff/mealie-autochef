# frozen_string_literal: true

require 'json'
require 'httparty'

module Autochef
  # Parses a freeform natural-language grocery list into structured items using Claude Haiku.
  # Each item gets a Food Lion-friendly search_term, quantity, and unit.
  class LlmItemParser
    ANTHROPIC_API_URL     = 'https://api.anthropic.com/v1/messages'
    ANTHROPIC_API_VERSION = '2023-06-01'
    HAIKU_MODEL           = 'claude-haiku-4-5-20251001'

    Item = Struct.new(:description, :search_term, :qty, :unit, keyword_init: true)

    def initialize(cfg)
      @cfg = cfg
    end

    # Parses freeform text like "milk, 2 lbs chicken thighs, and some cream cheese"
    # into an array of Item structs. Returns [] on error (caller handles gracefully).
    def parse(text)
      user_msg = <<~MSG
        Parse the following grocery shopping message into a structured list.

        For each item:
        - description: the user's original text for this item
        - search_term: a simple, clear Food Lion search term (e.g. "chicken thighs", "cream cheese", "whole milk")
        - qty: integer quantity to buy (default 1; infer from text like "2 lbs" or "a dozen")
        - unit: pack unit (lb, oz, ea, bag, bunch, carton, ct, gallon, etc.) or null if unit is unclear

        Message: "#{text}"

        Return ONLY a JSON array, no prose, no markdown fences:
        [{"description": "...", "search_term": "...", "qty": N, "unit": "..." or null}]
      MSG

      raw    = call_claude(user_msg)
      parsed = parse_json_array(raw)
      parsed.map do |h|
        Item.new(
          description: h['description'].to_s,
          search_term: h['search_term'].to_s.strip,
          qty:         [h['qty'].to_i, 1].max,
          unit:        h['unit']&.to_s&.strip&.then { |u| u.empty? ? nil : u }
        )
      end
    rescue StandardError => e
      warn "LlmItemParser#parse error: #{e.class}: #{e.message}"
      []
    end

    private

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
          max_tokens: 1024,
          messages:   [{ role: 'user', content: user_msg }]
        }.to_json,
        open_timeout: 10,
        read_timeout: 30
      )
      raise "Anthropic API HTTP #{resp.code}: #{resp.body.to_s.slice(0, 200)}" unless resp.success?

      resp.parsed_response.dig('content', 0, 'text') or raise 'Unexpected Anthropic response shape'
    end

    def parse_json_array(raw)
      clean  = raw.strip.gsub(/\A```(?:json)?\s*\n?/, '').gsub(/\n?```\s*\z/, '')
      parsed = JSON.parse(clean)
      raise "expected JSON array, got #{parsed.class}" unless parsed.is_a?(Array)

      parsed
    end
  end
end
