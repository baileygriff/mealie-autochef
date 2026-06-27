#!/usr/bin/env ruby
# frozen_string_literal: true

# Interactive recipe tagger for Mealie AutoChef.
#
# Phase 1 setup tool: walks through Mealie recipes and lets you assign:
#   - auto-plan tag (adds recipe to the eligible pool)
#   - cuisine:* tag (e.g. cuisine:american, cuisine:asian)
#   - protein:* tag (e.g. protein:chicken, protein:beef)
#   - effort:* tag  (effort:quick | effort:project)
#   - makes-leftovers tag
#
# After recipe tagging, separately walks through foods used in eligible
# recipes to set shelf_life_days in each food's extras.
#
# Usage:
#   bundle exec ruby scripts/tag_recipes.rb              # review all recipes
#   bundle exec ruby scripts/tag_recipes.rb --untagged   # only recipes without auto-plan
#   bundle exec ruby scripts/tag_recipes.rb --eligible   # only auto-plan-tagged recipes
#   bundle exec ruby scripts/tag_recipes.rb --foods-only # skip recipe tagging, do foods only

require 'bundler/setup'
require_relative '../lib/autochef/config'
require_relative '../lib/autochef/mealie_client'

SEPARATOR = ('━' * 60).freeze

CUISINE_OPTIONS = %w[italian asian american mexican mediterranean
                     indian middle-eastern greek french other].freeze

PROTEIN_OPTIONS = %w[chicken beef pork seafood lamb turkey
                     vegetarian vegan mixed].freeze

EFFORT_OPTIONS  = %w[quick project].freeze

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

def prompt(question, default: nil)
  suffix = default ? " [#{default}]" : ''
  print "#{question}#{suffix}: "
  $stdout.flush
  raw = $stdin.gets
  exit(0) if raw.nil? # EOF / Ctrl-D
  input = raw.chomp.strip
  input.empty? ? default.to_s : input
end

def yn(question, default: 'n')
  loop do
    answer = prompt("#{question} [y/n]", default: default).downcase
    return true  if answer == 'y'
    return false if answer == 'n'

    puts '  Please enter y or n.'
  end
end

def menu(label, options, allow_skip: true)
  puts "  #{label}:"
  options.each.with_index(1) { |opt, i| puts "    #{i}) #{opt}" }
  puts '    s) skip' if allow_skip
  loop do
    raw = prompt("  Choose (1-#{options.size}#{'/s' if allow_skip})")
    return nil if allow_skip && raw.downcase == 's'

    idx = raw.to_i
    return options[idx - 1] if idx.between?(1, options.size)

    puts '  Invalid choice — try again.'
  end
end

def tags_of_type(recipe, prefix)
  (recipe['tags'] || [])
    .map { |t| t['name'] }
    .select { |n| n.start_with?("#{prefix}:") }
end

def tag?(recipe, name)
  (recipe['tags'] || []).any? { |t| t['name'].to_s.casecmp?(name) }
end

def print_header(label)
  puts "\n#{SEPARATOR}"
  puts label
  puts SEPARATOR
end

def stars(rating)
  return 'unrated' if rating.nil? || rating.zero?

  full  = rating.to_i
  frac  = rating - full > 0.4 ? '½' : ''
  ('★' * full) + frac + " (#{rating})"
end

# ─────────────────────────────────────────────────────────────
# Recipe tagging session
# ─────────────────────────────────────────────────────────────

def tag_recipe_interactively(client, recipe, eligible_tag, index, total)
  slug     = recipe['slug'] || recipe['id']
  name     = recipe['name'] || slug
  existing = (recipe['tags'] || []).map { |t| t['name'] }
  is_eligible = tag?(recipe, eligible_tag)

  puts "\n#{SEPARATOR}"
  puts "[#{index}/#{total}] #{name}"
  puts "  slug:    #{slug}"
  puts "  rating:  #{stars(recipe['rating'])}"
  puts "  made:    #{recipe['lastMade'] || 'never'}"
  puts "  tags:    #{existing.empty? ? '(none)' : existing.join(', ')}"
  puts SEPARATOR

  new_tags = []

  unless is_eligible
    add_to_pool = yn('Add to auto-plan pool?', default: 'n')
    unless add_to_pool
      puts '  Skipping (not added to pool).'
      return :skipped
    end
    new_tags << eligible_tag
  end

  # Cuisine
  existing_cuisine = tags_of_type(recipe, 'cuisine')
  if existing_cuisine.empty?
    puts "\nCuisine:"
    cuisine = menu('Type', CUISINE_OPTIONS)
    new_tags << "cuisine:#{cuisine}" if cuisine
  else
    puts "  cuisine: #{existing_cuisine.join(', ')} (already set — skipping)"
  end

  # Protein
  existing_protein = tags_of_type(recipe, 'protein')
  if existing_protein.empty?
    puts "\nProtein:"
    protein = menu('Main protein', PROTEIN_OPTIONS)
    new_tags << "protein:#{protein}" if protein
  else
    puts "  protein: #{existing_protein.join(', ')} (already set — skipping)"
  end

  # Effort
  existing_effort = tags_of_type(recipe, 'effort')
  if existing_effort.empty?
    puts "\nEffort:"
    effort = menu('Cooking effort', EFFORT_OPTIONS)
    new_tags << "effort:#{effort}" if effort
  else
    puts "  effort: #{existing_effort.join(', ')} (already set — skipping)"
  end

  # Makes leftovers
  if !tag?(recipe, 'makes-leftovers') && yn('Makes enough leftovers for a second meal?', default: 'n')
    new_tags << 'makes-leftovers'
  end

  if new_tags.empty?
    puts '  No changes.'
    return :unchanged
  end

  begin
    client.add_recipe_tags(slug, new_tags)
    puts "  ✓ Added: #{new_tags.join(', ')}"
    :updated
  rescue StandardError => e
    puts "  ✗ API error: #{e.message}"
    :error
  end
end

# ─────────────────────────────────────────────────────────────
# Food shelf-life session
# ─────────────────────────────────────────────────────────────

def collect_eligible_foods(client, pool)
  food_ids = {} # food_id → food hash (deduped)

  pool.each do |r|
    full = begin
      client.recipe(r['slug'] || r['id'])
    rescue StandardError
      next
    end

    ingredients = full['recipeIngredient'] || []
    ingredients.each do |ing|
      food = ing['food']
      next if food.nil? || food['id'].nil?
      next if food['onHand'] # On-Hand foods never hit the shopping list

      food_ids[food['id']] ||= food
    end
  end

  food_ids.values
end

def set_food_shelf_life_interactively(client, foods_list)
  print_header('Food shelf-life setup')
  puts 'Setting shelf_life_days on ingredients used in eligible recipes.'
  puts 'Foods with onHand=true are skipped (they never hit the shopping list).'
  puts "Press Enter to accept a suggestion, or type a number. 's' to skip a food.\n"

  needs_setup = foods_list.reject do |f|
    extras = f['extras'] || {}
    extras['shelf_life_days'].to_i.positive?
  end

  already_set = foods_list.size - needs_setup.size
  puts "\n  #{foods_list.size} unique foods — #{already_set} already have " \
       "shelf_life_days set, #{needs_setup.size} need it."

  if needs_setup.empty?
    puts '  Nothing to do here. ✓'
    return
  end

  set_count = 0
  needs_setup.each.with_index(1) do |food, i|
    food_name = food['name'] || food['id']
    suggested = Autochef::MealieClient.suggest_shelf_life(food_name)

    print "\n[#{i}/#{needs_setup.size}] #{food_name}"
    extras = food['extras'] || {}
    puts " (current extras: #{extras})" unless extras.empty?
    puts " (suggested: #{suggested} days)"

    raw = prompt('  shelf_life_days', default: suggested.to_s)
    if raw.downcase == 's'
      puts '  Skipped.'
      next
    end

    days = raw.to_i
    if days <= 0
      puts '  Invalid number — skipped.'
      next
    end

    begin
      client.update_food_extras(food['id'], { 'shelf_life_days' => days })
      puts "  ✓ Set to #{days} day(s)."
      set_count += 1
    rescue StandardError => e
      puts "  ✗ API error: #{e.message}"
    end
  end

  puts "\nFood shelf-life: set #{set_count}/#{needs_setup.size} food(s)."
end

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

def main
  mode       = :all
  foods_only = false

  ARGV.each do |arg|
    case arg
    when '--untagged'   then mode = :untagged
    when '--eligible'   then mode = :eligible
    when '--foods-only' then foods_only = true
    when '--help', '-h'
      puts <<~USAGE
        Usage: bundle exec ruby scripts/tag_recipes.rb [options]
          (no flag)      Review all recipes
          --untagged     Only recipes not yet tagged auto-plan
          --eligible     Only already-eligible recipes (to add cuisine/protein/effort)
          --foods-only   Skip recipe tagging, go straight to food shelf-life setup
          --help         Show this message
      USAGE
      return 0
    end
  end

  begin
    cfg = Autochef::Config.load
  rescue StandardError => e
    puts "Config load failed: #{e.message}"
    return 1
  end

  client = Autochef::MealieClient.new(base_url: cfg.mealie.url, api_token: cfg.mealie.api_token)
  eligible_tag = cfg.mealie.eligible_tag

  print "\nConnecting to Mealie at #{cfg.mealie.url}... "
  $stdout.flush

  begin
    about   = client.ping
    version = about.is_a?(Hash) ? about['version'] : '?'
    puts "OK (v#{version})"
  rescue StandardError => e
    puts "FAILED\n#{e.message}"
    puts 'Tip: set MEALIE_URL=http://localhost:9000 in .env for local dev.'
    return 1
  end

  print 'Fetching all recipes... '
  $stdout.flush

  begin
    all_recipes = client.recipes
  rescue StandardError => e
    puts "FAILED\n#{e.message}"
    return 1
  end

  puts "#{all_recipes.size} found."

  eligible_recipes = all_recipes.select { |r| tag?(r, eligible_tag) }
  puts "  #{eligible_recipes.size} already tagged '#{eligible_tag}'"

  unless foods_only
    recipes_to_review = case mode
                        when :untagged  then all_recipes.reject { |r| tag?(r, eligible_tag) }
                        when :eligible  then eligible_recipes
                        else all_recipes
                        end

    print_header("Recipe tagging — #{recipes_to_review.size} to review (mode: #{mode})")
    puts "Keys: y/n = yes/no  |  s = skip  |  number = pick from menu  |  Ctrl-D to quit\n"

    counts = Hash.new(0)
    recipes_to_review.each.with_index(1) do |r, i|
      result = tag_recipe_interactively(client, r, eligible_tag, i, recipes_to_review.size)
      counts[result] += 1
    end

    puts "\n#{SEPARATOR}"
    puts 'Recipe tagging complete:'
    puts "  Updated:   #{counts[:updated]}"
    puts "  Unchanged: #{counts[:unchanged]}"
    puts "  Skipped:   #{counts[:skipped]}"
    puts "  Errors:    #{counts[:error]}"

    # Re-fetch eligible pool after tagging so the food section sees newly-added recipes.
    print "\nRe-fetching eligible pool for food shelf-life setup... "
    $stdout.flush
    eligible_recipes = begin
      client.eligible_pool(eligible_tag)
    rescue StandardError => e
      puts "FAILED (#{e.message}) — using pre-tagging list"
      eligible_recipes
    end
    puts "#{eligible_recipes.size} recipe(s)."
  end

  if eligible_recipes.empty?
    puts 'No eligible recipes — skipping food shelf-life setup.'
    puts "Tag at least one recipe '#{eligible_tag}' first."
    return 0
  end

  print_header("Fetching ingredients from #{eligible_recipes.size} eligible recipe(s)...")
  puts "(This makes one API call per recipe — may take a moment.)\n"

  foods_list = collect_eligible_foods(client, eligible_recipes)
  puts "Found #{foods_list.size} unique non-pantry food(s) across eligible recipes."

  if foods_list.empty?
    puts 'No foods to set up — check that recipes have ingredients with food references in Mealie.'
    return 0
  end

  set_food_shelf_life_interactively(client, foods_list)

  puts "\n#{SEPARATOR}"
  puts 'Phase 1 setup complete.'
  puts 'Next: run `bundle exec ruby main.rb sync` to pull ratings into recipe_stats.'
  puts SEPARATOR
  0
end

exit(main) if __FILE__ == $PROGRAM_NAME
