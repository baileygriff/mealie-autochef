#!/usr/bin/env ruby
# frozen_string_literal: true

# Interactive product map seeder for Phase 4/5.
#
# Usage:
#   bundle exec ruby scripts/seed_product_map.rb
#   bundle exec ruby scripts/seed_product_map.rb --unmapped   # only unmapped ingredients
#   bundle exec ruby scripts/seed_product_map.rb --list       # list existing mappings
#   bundle exec ruby scripts/seed_product_map.rb --update     # re-map already-mapped items
#
# For each unmapped ingredient from the most recent approved plan, prompts for:
#   - Search term (what to search on Food Lion To Go — defaults to the food name)
#   - Pack size (numeric, e.g. 16)
#   - Pack unit (oz, lb, ct, etc.)
#   - Default quantity to buy (packs, default 1)
#   - Rounding rule (up / down / nearest, default up)
#   - Optional display name override

$LOAD_PATH.unshift(File.expand_path('..', __dir__))

require_relative '../lib/autochef/config'
require_relative '../lib/autochef/database'
require_relative '../lib/autochef/models/plan_history'
require_relative '../lib/autochef/models/product_map'

cfg = Autochef::Config.load
Autochef::Database.connect!
Autochef::Database.migrate!

mode = ARGV[0]

def normalize(name)
  name.to_s.downcase.strip.gsub(/\s+/, ' ')
end

def prompt(label, default: nil)
  default_hint = default ? " [#{default}]" : ''
  print "#{label}#{default_hint}: "
  $stdout.flush
  input = $stdin.gets&.chomp&.strip
  (input.nil? || input.empty?) ? default : input
end

def confirm(msg)
  print "#{msg} [y/N]: "
  $stdout.flush
  $stdin.gets&.chomp&.strip&.downcase == 'y'
end

# --list: show all existing mappings
if mode == '--list'
  mappings = Autochef::Models::ProductMap.order(:key)
  if mappings.empty?
    puts 'No product mappings found.'
  else
    puts "#{mappings.count} product mapping(s):\n\n"
    mappings.each do |m|
      puts "  #{m.key}"
      puts "    search: #{m.search_term}"
      puts "    pack:   #{m.pack_size} #{m.pack_unit} × #{m.default_qty} (round #{m.rounding || 'up'})"
      puts "    display: #{m.display_name}" if m.display_name.to_s.strip.length.positive?
      puts
    end
  end
  exit 0
end

# Collect ingredients from the most recent approved plan.
recent = Autochef::Models::PlanHistory.where(approved: 1).order(created_at: :desc).first

if recent.nil?
  puts 'No approved plans in the database. Approve a plan first.'
  puts 'You can also map items manually with a key and --update flag.'
  exit 1
end

puts "Using approved plan id=#{recent.id} (week of #{recent.week_start}).\n\n"

all_food_names = []
recent.plan.each_value do |entry|
  next unless entry['recipe_id']

  # Pull food names from the plan JSON. Full ingredient details require Mealie
  # access; here we just pick up any food_name keys stored by the shopping builder.
  # Fall back gracefully if not present — the user can still seed arbitrary keys.
  (entry['ingredients'] || []).each do |ing|
    name = ing['food_name'].to_s.strip
    all_food_names << name unless name.empty?
  end
end

# Deduplicate and normalize keys.
food_keys = all_food_names.map { |n| normalize(n) }.uniq.sort

if food_keys.empty?
  puts "No ingredient data embedded in this plan's JSON."
  puts "Tip: run `main.rb shop` first — it will report unmapped items."
  puts "Then re-run this script and enter keys manually, or provide a list below.\n\n"
  puts 'Enter ingredient names to map (one per line, blank to finish):'
  loop do
    input = $stdin.gets&.chomp&.strip
    break if input.nil? || input.empty?

    food_keys << normalize(input)
  end
  food_keys.uniq!
end

existing_keys = Autochef::Models::ProductMap.pluck(:key).to_set

to_seed = if mode == '--update'
            food_keys  # re-prompt even mapped items
          else
            food_keys.reject { |k| existing_keys.include?(k) }
          end

if to_seed.empty?
  puts 'All ingredients are already mapped. Use --update to re-map existing entries.'
  exit 0
end

puts "#{to_seed.size} ingredient(s) to map:\n\n"

to_seed.each_with_index do |key, idx|
  puts "--- [#{idx + 1}/#{to_seed.size}] #{key} ---"

  existing = Autochef::Models::ProductMap.find_by(key: key)
  if existing && mode != '--update'
    puts "  Already mapped (search: #{existing.search_term}) — skipping. Use --update to change."
    next
  end

  search_term  = prompt('  Search term on Food Lion', default: key)
  display_name = prompt('  Display name (blank = use food name)', default: nil)
  pack_size    = prompt('  Pack size (e.g. 16)', default: nil)&.to_f
  pack_unit    = prompt('  Pack unit (oz / lb / ct / ea)', default: 'ct')
  default_qty  = prompt('  Default qty to buy (packs)', default: '1')&.to_i
  rounding     = prompt('  Rounding (up / down / nearest)', default: 'up')
  notes        = prompt('  Substitution notes (optional)', default: nil)

  puts

  record = Autochef::Models::ProductMap.find_or_initialize_by(key: key)
  record.search_term        = search_term
  record.display_name       = display_name.to_s.strip.empty? ? nil : display_name
  record.pack_size          = pack_size&.positive? ? pack_size : nil
  record.pack_unit          = pack_unit.to_s.strip.empty? ? nil : pack_unit
  record.default_qty        = [default_qty.to_i, 1].max
  record.rounding           = %w[up down nearest].include?(rounding) ? rounding : 'up'
  record.substitution_notes = notes.to_s.strip.empty? ? nil : notes

  if record.valid?
    record.save!
    puts "  ✓ Saved: #{key} → \"#{search_term}\""
  else
    puts "  ✗ Validation failed: #{record.errors.full_messages.join(', ')}"
  end

  puts
end

puts "\nDone. Run `bundle exec ruby main.rb shop` to rebuild the list with the new mappings."
