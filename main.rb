#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entrypoint for Mealie AutoChef.
#
# Usage:
#   bundle exec ruby main.rb check        # Phase 0/1 sanity check
#   bundle exec ruby main.rb sync         # Phase 1: pull Mealie → recipe_stats
#   bundle exec ruby main.rb plan         # Phase 2+3: generate plan + send Telegram draft
#   bundle exec ruby main.rb serve        # Phase 3: long-running Telegram bot (approval + commands)
#   bundle exec ruby main.rb build-cart   # Phase 5
#   bundle exec ruby main.rb backup       # Phase 6

require 'httparty'
require_relative 'lib/autochef/config'
require_relative 'lib/autochef/database'
require_relative 'lib/autochef/mealie_client'
require_relative 'lib/autochef/models/recipe_stat'
require_relative 'lib/autochef/models/plan_history'
require_relative 'lib/autochef/models/manual_addition'
require_relative 'lib/autochef/models/recurring_item'
require_relative 'lib/autochef/scoring'
require_relative 'lib/autochef/planner'
require_relative 'lib/autochef/llm_planner'
require_relative 'lib/autochef/notify'

def ping_uptime_kuma(push_url)
  return false if push_url.to_s.empty?

  resp = HTTParty.get(push_url, timeout: 10)
  if resp.success?
    puts "Uptime Kuma ping OK (#{resp.code})"
    true
  else
    puts "Uptime Kuma ping FAILED: HTTP #{resp.code}"
    false
  end
rescue StandardError => e
  # Never let a healthcheck failure crash the run it's reporting on.
  puts "Uptime Kuma ping error: #{e.message}"
  false
end

def build_client(cfg)
  Autochef::MealieClient.new(base_url: cfg.mealie.url, api_token: cfg.mealie.api_token)
end

def cmd_check
  puts '=== Mealie AutoChef — Phase 0/1 sanity check ==='

  begin
    cfg = Autochef::Config.load
  rescue StandardError => e
    puts "Config load FAILED: #{e.message}"
    return 1
  end
  puts "Config loaded OK (mealie: #{cfg.mealie.url}, store: #{cfg.store.name})"

  begin
    Autochef::Database.connect!
    Autochef::Database.migrate!
  rescue StandardError => e
    puts "DB init/migrate FAILED: #{e.message}"
    return 1
  end
  puts 'Database initialized and migrated OK.'

  client = build_client(cfg)
  mealie_ok = false

  begin
    about = client.ping
    version = about.is_a?(Hash) ? about['version'] : '?'
    puts "Mealie reachable at #{cfg.mealie.url} — version #{version}"
    mealie_ok = true
  rescue Autochef::MealieClient::AuthError => e
    puts "Mealie auth FAILED: #{e.message}"
  rescue StandardError => e
    puts "Mealie connection FAILED: #{e.message}"
  end

  if mealie_ok
    # Quick auth check: try the eligible pool.
    begin
      pool = client.eligible_pool(cfg.mealie.eligible_tag)
      puts "Eligible pool: #{pool.size} recipe(s) tagged '#{cfg.mealie.eligible_tag}'"
    rescue StandardError => e
      puts "Eligible pool query failed: #{e.message}"
      mealie_ok = false
    end
  end

  ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))

  if mealie_ok
    puts "\nResult: OK"
    0
  else
    puts "\nResult: PARTIAL — config/db OK, Mealie unreachable (expected if Mealie"
    puts "isn't on mealie_net yet, or this isn't running inside Docker)."
    puts 'Tip: set MEALIE_URL=http://localhost:9000 in .env to point at your local Mealie.'
    1
  end
end

def cmd_sync
  puts '=== Mealie AutoChef — sync (pull Mealie → recipe_stats) ==='

  begin
    cfg = Autochef::Config.load
  rescue StandardError => e
    puts "Config load FAILED: #{e.message}"
    return 1
  end

  begin
    Autochef::Database.connect!
    Autochef::Database.migrate!
  rescue StandardError => e
    puts "DB init/migrate FAILED: #{e.message}"
    return 1
  end

  client = build_client(cfg)

  begin
    about = client.ping
    version = about.is_a?(Hash) ? about['version'] : '?'
    puts "Connected to Mealie #{version} at #{cfg.mealie.url}"
  rescue StandardError => e
    puts "Cannot reach Mealie: #{e.message}"
    puts 'Tip: set MEALIE_URL=http://localhost:9000 in .env for local dev.'
    return 1
  end

  begin
    pool = client.eligible_pool(cfg.mealie.eligible_tag)
  rescue StandardError => e
    puts "Failed to fetch eligible pool: #{e.message}"
    return 1
  end

  puts "Found #{pool.size} eligible recipe(s) tagged '#{cfg.mealie.eligible_tag}'"

  if pool.empty?
    puts "Nothing to sync. Tag some recipes '#{cfg.mealie.eligible_tag}' in Mealie"
    puts 'or run:  bundle exec ruby scripts/tag_recipes.rb'
    ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))
    return 0
  end

  synced   = 0
  skipped  = 0
  errors   = []

  pool.each do |r|
    recipe_id = r['id']
    next if recipe_id.to_s.empty?

    begin
      stat = Autochef::Models::RecipeStat.find_or_initialize_by(recipe_id: recipe_id)
      # Only write fields sourced from Mealie; preserve autochef internal counters
      # (times_planned, times_cooked, times_swapped_out, score) — those are ours.
      stat.avg_rating  = r['rating']
      stat.last_cooked = r['lastMade']
      stat.save!
      synced += 1
    rescue StandardError => e
      errors << "#{r['name']} (#{recipe_id}): #{e.message}"
      skipped += 1
    end
  end

  puts "Synced #{synced} recipe stat(s)."
  puts "Skipped #{skipped} due to errors:" if skipped.positive?
  errors.each { |msg| puts "  - #{msg}" }

  ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))
  errors.empty? ? 0 : 1
end

def cmd_plan(freeform_note: nil)
  puts '=== Mealie AutoChef — plan (Phase 2) ==='

  begin
    cfg = Autochef::Config.load
  rescue StandardError => e
    puts "Config load FAILED: #{e.message}"
    return 1
  end

  begin
    Autochef::Database.connect!
    Autochef::Database.migrate!
  rescue StandardError => e
    puts "DB init/migrate FAILED: #{e.message}"
    return 1
  end

  client = build_client(cfg)

  begin
    pool = client.eligible_pool(cfg.mealie.eligible_tag)
  rescue StandardError => e
    puts "Cannot fetch eligible pool from Mealie: #{e.message}"
    puts 'Tip: set MEALIE_URL in .env or run inside Docker.'
    return 1
  end

  puts "Eligible pool: #{pool.size} recipe(s) tagged '#{cfg.mealie.eligible_tag}'"

  if pool.empty?
    puts "Nothing to plan. Tag some recipes '#{cfg.mealie.eligible_tag}' in Mealie."
    return 1
  end

  # Decorate pool with perishability (min shelf_life_days of non-on-hand ingredients).
  # We resolve this from each recipe's ingredients' food extras. Falls back to 365
  # if ingredients aren't fetched or data is missing (acceptable for Phase 2 smoke test).
  pool = resolve_perishability(pool, client)

  # Score all eligible recipes.
  scorer     = Autochef::Scorer.new(cfg)
  recipe_map = pool.to_h { |r| [r['id'], r] }

  # Fetch nutrition data for recipes that have it, for protein-fit scoring.
  nutrition_map = resolve_nutrition(pool, client)
  scorer.update_scores!(recipe_map, nutrition_map: nutrition_map)

  scored_ids = Autochef::Models::RecipeStat.all.to_h do |s|
    [s.recipe_id, s.score.to_f]
  end

  # Load recent plans for LLM context + repeat-avoidance.
  recent_plans = Autochef::Models::PlanHistory
                 .order(created_at: :desc)
                 .limit(4)
                 .map(&:plan)

  # Plan.
  llm     = Autochef::LlmPlanner.new(cfg)
  result  = llm.plan(pool: pool, scored_ids: scored_ids,
                     freeform_note: freeform_note, recent_plans: recent_plans)
  plan    = result.week_plan

  # Print.
  puts "\n--- Week of #{plan.week_start.strftime('%A, %B %-d, %Y')} ---"
  puts "(via #{result.via_llm ? 'Claude' : 'deterministic planner'})"

  if plan.assignments.empty?
    puts 'No assignments generated.'
  else
    plan.assignments.each do |a|
      label    = "#{a.day_name} #{a.date.strftime('%b %-d')}"
      servings = "#{a.servings} servings"
      perishability = a.perishability < 365 ? "  [perishable: #{a.perishability}d]" : ''
      rationale = a.rationale.to_s.empty? ? '' : "\n    #{a.rationale}"
      puts "  #{label}: #{a.recipe_name} (#{servings})#{perishability}#{rationale}"
    end
  end

  if plan.warnings.any?
    puts "\nWarnings:"
    plan.warnings.each { |w| puts "  ⚠  #{w}" }
  end

  puts "\nLLM note: #{result.llm_error}" if result.llm_error

  # Persist to plan_history.
  assignments_hash = plan.assignments.to_h do |a|
    [a.date.iso8601, {
      'recipe_id'       => a.recipe_id,
      'recipe_name'     => a.recipe_name,
      'servings'        => a.servings,
      'meal_type'       => a.meal_type,
      'makes_leftovers' => a.makes_leftovers,
      'rationale'       => a.rationale
    }]
  end

  history = Autochef::Models::PlanHistory.new(
    week_start: plan.week_start,
    plan_json: assignments_hash.to_json,
    approved: 0,
    swaps_json: {}.to_json
  )
  history.save!
  puts "\nPlan saved to plan_history (id=#{history.id})."

  # Increment times_planned for each chosen recipe.
  plan.assignments.each do |a|
    stat = Autochef::Models::RecipeStat.find_or_initialize_by(recipe_id: a.recipe_id)
    stat.times_planned  = stat.times_planned.to_i + 1
    stat.last_planned   = plan.week_start
    stat.save!
  end

  # Send draft to Telegram for approval (Phase 3).
  if cfg.notify.channel == 'telegram' && !cfg.notify.telegram_bot_token.to_s.empty?
    begin
      notifier = Autochef::Notifier.new(cfg, mealie_client: client)
      notifier.send_draft(plan_history_id: history.id)
      puts "Plan draft sent to Telegram (plan_history id=#{history.id})."
      puts 'Start `bundle exec ruby main.rb serve` to handle approval buttons.'
    rescue StandardError => e
      puts "Telegram send FAILED: #{e.message}"
      puts "(Plan is saved — you can still approve manually.)"
    end
  else
    puts '(Telegram not configured — skipping notification.)'
  end

  ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))
  0
end

def resolve_perishability(pool, client)
  pool.map do |recipe|
    # Try to fetch full recipe to get ingredient food extras (shelf_life_days).
    full = client.recipe(recipe['id'])
    ingredients = full['recipeIngredient'] || []

    shelf_lives = ingredients.filter_map do |ing|
      food = ing['food']
      next if food.nil?
      # on_hand foods are excluded from perishability (we're not buying them)
      next if food['onHand']

      extras = food['extras'] || {}
      days   = extras['shelf_life_days']&.to_i
      # fallback to name-based heuristic
      days ||= Autochef::MealieClient.suggest_shelf_life(food['name'].to_s)
      days
    end

    recipe.merge('perishability' => shelf_lives.min || 365)
  rescue StandardError
    recipe.merge('perishability' => 365)
  end
end

def resolve_nutrition(pool, client)
  pool.each_with_object({}) do |recipe, map|
    full = client.recipe(recipe['id'])
    nd   = full['nutritionData'] || full['nutrition']
    bs   = full['recipeYield']&.to_i || 2
    map[recipe['id']] = { nutrition_data: nd, base_servings: [bs, 1].max }
  rescue StandardError
    # leave this recipe out of the nutrition map; scorer falls back to tag heuristic
  end
end

def cmd_serve
  puts '=== Mealie AutoChef — serve (Phase 3 Telegram bot) ==='

  begin
    cfg = Autochef::Config.load
  rescue StandardError => e
    puts "Config load FAILED: #{e.message}"
    return 1
  end

  begin
    Autochef::Database.connect!
    Autochef::Database.migrate!
  rescue StandardError => e
    puts "DB init/migrate FAILED: #{e.message}"
    return 1
  end

  if cfg.notify.channel != 'telegram' || cfg.notify.telegram_bot_token.to_s.empty?
    puts 'Telegram not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env.'
    return 1
  end

  client  = build_client(cfg)
  scorer  = Autochef::Scorer.new(cfg)
  planner = Autochef::Planner.new(cfg)
  llm     = Autochef::LlmPlanner.new(cfg, planner: planner)

  notifier = Autochef::Notifier.new(cfg,
                                    mealie_client: client,
                                    scorer: scorer,
                                    llm_planner: llm)
  notifier.run_bot
  0
end

def not_implemented_yet(command)
  puts "`#{command}` is not implemented yet — it lands in a later build phase."
  puts 'See MEALIE_AUTOMATION_PLAN.md section 10 for the phase breakdown.'
  1
end

def main
  command = ARGV[0]

  case command
  when 'check'
    cmd_check
  when 'serve'
    cmd_serve
  when 'sync'
    cmd_sync
  when 'plan'
    cmd_plan(freeform_note: ARGV[1])
  when 'build-cart', 'backup'
    not_implemented_yet(command)
  when nil
    puts 'Usage: ruby main.rb <check|sync|serve|plan|build-cart|backup>'
    1
  else
    puts "Unknown command: #{command}"
    1
  end
end

exit(main) if __FILE__ == $PROGRAM_NAME
