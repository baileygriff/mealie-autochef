#!/usr/bin/env ruby
# frozen_string_literal: true

# LLM-assisted product map seeder (Feature 6).
#
# Suggests Food Lion search terms, quantities, and pantry-skip flags for
# unmapped ingredients in the current Mealie "Next Order" shopping list.
#
# Usage:
#   bundle exec ruby scripts/auto_map.rb
#
# Runs the mapping pass, prints results, and exits.
# Flags suspicious existing mappings but does NOT overwrite them — use
# seed_product_map.rb --update to correct flagged entries manually.

$LOAD_PATH.unshift(File.expand_path('..', __dir__))

require_relative '../lib/autochef/config'
require_relative '../lib/autochef/database'
require_relative '../lib/autochef/mealie_client'
require_relative '../lib/autochef/models/plan_history'
require_relative '../lib/autochef/models/product_map'
require_relative '../lib/autochef/llm_recipe_mapper'

cfg = Autochef::Config.load
Autochef::Database.connect!
Autochef::Database.migrate!

unless cfg.llm.enabled
  puts 'LLM not enabled — set llm.enabled: true in config.yaml'
  exit 1
end

history = Autochef::Models::PlanHistory.where(approved: 1).order(created_at: :desc).first
if history.nil?
  puts 'No approved plans in the database. Approve a plan first.'
  exit 1
end
puts "Using approved plan id=#{history.id} (week of #{history.week_start})."

mealie = Autochef::MealieClient.new(base_url: cfg.mealie.url, api_token: cfg.mealie.api_token)
begin
  mealie.ping
rescue StandardError => e
  puts "Cannot reach Mealie: #{e.message}"
  exit 1
end

mapper = Autochef::LlmRecipeMapper.new(cfg)
puts "\nRunning LLM-assisted recipe mapping..."
result = mapper.map_unmapped(mealie_client: mealie, plan_history: history)

if result.errors.any?
  puts "\nErrors:"
  result.errors.each { |e| puts "  ✗ #{e}" }
end

if result.new_mapped.any?
  puts "\nMapped #{result.new_mapped.size} new ingredient(s):"
  result.new_mapped.each do |m|
    unit_str = m[:unit] ? " (#{m[:qty]} #{m[:unit]})" : " (qty: #{m[:qty]})"
    puts "  ✓ #{m[:key]} → #{m[:search_term]}#{unit_str}"
  end
end

if result.pantry_skipped.any?
  puts "\nMarked #{result.pantry_skipped.size} pantry staple(s) as skip:"
  result.pantry_skipped.each { |k| puts "  ✓ #{k} → __skip__" }
end

if result.suspicious.any?
  puts "\n#{result.suspicious.size} suspicious existing mapping(s) — review manually:"
  result.suspicious.each do |s|
    puts "  ⚠  #{s['ingredient_name']}: #{s['concern']}"
  end
  puts "  Run: bundle exec ruby scripts/seed_product_map.rb --update"
end

if result.new_mapped.empty? && result.pantry_skipped.empty? && result.suspicious.empty? && result.errors.empty?
  puts "\nAll ingredients already mapped — nothing to do."
end

exit(result.errors.empty? ? 0 : 1)
