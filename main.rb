#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entrypoint for Mealie AutoChef.
#
# Usage:
#   bundle exec ruby main.rb check        # Phase 0/1 sanity check
#   bundle exec ruby main.rb sync         # Phase 1: pull Mealie → recipe_stats
#   bundle exec ruby main.rb plan         # Phase 2+3: generate plan + send Telegram draft
#   bundle exec ruby main.rb serve        # Phase 3+6: long-running Telegram bot + reminder scheduler
#   bundle exec ruby main.rb shop         # Phase 4: build shopping list from approved plan
#   bundle exec ruby main.rb build-cart   # Phase 5
#   bundle exec ruby main.rb feedback     # Phase 6: apply kept/cooked signals to recipe_stats + tag_weights
#   bundle exec ruby main.rb budget       # Phase 6: print monthly/YTD spend from order_history
#   bundle exec ruby main.rb backup       # Phase 6: dump SQLite + trigger Mealie backup

require 'fileutils'
require 'httparty'
require 'rufus-scheduler'
require_relative 'lib/autochef/config'
require_relative 'lib/autochef/database'
require_relative 'lib/autochef/mealie_client'
require_relative 'lib/autochef/models/recipe_stat'
require_relative 'lib/autochef/models/plan_history'
require_relative 'lib/autochef/models/order_history'
require_relative 'lib/autochef/models/manual_addition'
require_relative 'lib/autochef/models/recurring_item'
require_relative 'lib/autochef/models/product_map'
require_relative 'lib/autochef/scoring'
require_relative 'lib/autochef/planner'
require_relative 'lib/autochef/llm_planner'
require_relative 'lib/autochef/recurring'
require_relative 'lib/autochef/shopping'
require_relative 'lib/autochef/safety'
require_relative 'lib/autochef/cart_client'
require_relative 'lib/autochef/llm_qty_consolidator'
require_relative 'lib/autochef/llm_recipe_mapper'
require_relative 'lib/autochef/notify'
require_relative 'lib/autochef/reminders'
require_relative 'lib/autochef/feedback'
require_relative 'lib/autochef/week_prefs_source'
require_relative 'lib/autochef/sinatra_prefs_source'
require_relative 'lib/autochef/models/week_pref'
require_relative 'lib/autochef/web/app'

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

# Mirror Planner#next_week_start for use outside Planner instances.
def week_start_for(cfg)
  order    = %w[Sun Mon Tue Wed Thu Fri Sat]
  wday_idx = order.index(cfg.schedule.pickup_day) || 0
  today    = Date.today
  offset   = (wday_idx - today.wday) % 7
  offset   = 7 if offset.zero?
  today + offset
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

  # Apply week prefs from the Sinatra form (if any were submitted for this week).
  prefs_source     = Autochef::SinatraPrefsSource.new
  next_ws          = week_start_for(cfg)
  week_prefs       = prefs_source.fetch(next_ws)
  layout_overrides   = {}
  servings_overrides = {}
  combined_note    = freeform_note

  if week_prefs
    # Hard-filter pool by protein exclusions.
    week_prefs.protein_excludes.each do |excluded|
      pool.reject! { |r| (r['tags'] || []).any? { |t| t['name'] == "protein:#{excluded}" } }
    end

    # Build per-day layout and servings override hashes keyed by Date.
    week_prefs.days.each do |date_str, dp|
      date = Date.parse(date_str.to_s)
      layout_overrides[date]   = dp if dp.meal_type
      servings_overrides[date] = dp.dinner&.servings if dp.dinner&.servings
    end

    # Build combined freeform note: global + per-day treat/note labels.
    vibe_notes = week_prefs.days.filter_map do |date_str, dp|
      next unless dp.dinner
      label = dp.dinner.vibe == 'treat' ? 'Treat meal' : nil
      note  = dp.dinner.note.to_s.strip
      next unless label || !note.empty?

      "#{Date.parse(date_str.to_s).strftime('%a')} #{[label, note].compact.join(': ')}"
    end
    parts = [week_prefs.freeform_note, *vibe_notes].reject(&:empty?)
    combined_note = parts.any? ? parts.join('. ') : freeform_note
  end

  # Plan.
  llm     = Autochef::LlmPlanner.new(cfg)
  result  = llm.plan(pool: pool, scored_ids: scored_ids,
                     freeform_note: combined_note, recent_plans: recent_plans,
                     layout_overrides: layout_overrides,
                     servings_overrides: servings_overrides)
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

  # Increment times_planned; last_planned is set on approval, not on draft save.
  plan.assignments.each do |a|
    stat = Autochef::Models::RecipeStat.find_or_initialize_by(recipe_id: a.recipe_id)
    stat.times_planned = stat.times_planned.to_i + 1
    stat.save!
  end

  # Send draft to Telegram for approval (Phase 3).
  if cfg.notify.channel == 'telegram' && !cfg.notify.telegram_bot_token.to_s.empty?
    begin
      notifier = Autochef::Notifier.new(cfg, mealie_client: client)
      notifier.send_draft(plan_history_id: history.id, note: result.llm_error)
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
rescue StandardError => e
  puts "FATAL (#{e.class}): #{e.message}"
  begin
    cfg ||= Autochef::Config.load
    Autochef::Notifier.send_crash_alert(cfg, 'plan', e)
    puts "Crash alert sent to Telegram."
  rescue StandardError
    nil
  end
  1
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

  # Start Sinatra week configurator in a background thread (non-blocking).
  if cfg.web.enabled
    prefs_source = Autochef::SinatraPrefsSource.new
    Autochef::Web::App.configure_autochef(cfg: cfg, prefs_source: prefs_source)
    Thread.new do
      Autochef::Web::App.run!(port: cfg.web.port, bind: '0.0.0.0', quiet: true)
    end
    puts "Week configurator running at http://#{cfg.web.host}:#{cfg.web.port}/week"
  end

  # Start reminder scheduler in background threads before the blocking bot loop.
  scheduler = Rufus::Scheduler.new
  reminders = Autochef::Reminders.new(cfg, notifier: notifier)
  reminders.schedule!(scheduler)

  begin
    notifier.run_bot  # blocks until process is killed
  ensure
    scheduler.shutdown
  end

  0
end

def cmd_shop
  puts '=== Mealie AutoChef — shop (Phase 4: build shopping list) ==='

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
    client.ping
  rescue StandardError => e
    puts "Cannot reach Mealie: #{e.message}"
    puts 'Tip: set MEALIE_URL in .env or run inside Docker.'
    return 1
  end

  history = Autochef::Models::PlanHistory.where(approved: 1).order(created_at: :desc).first
  if history.nil?
    puts 'No approved plan found. Run `main.rb plan` and approve it first.'
    return 1
  end

  puts "Using approved plan id=#{history.id} (week of #{history.week_start})."

  builder = Autochef::ShoppingListBuilder.new(cfg, mealie_client: client)
  result  = builder.build_and_push(history)

  puts "\n--- Shopping list pushed to Mealie \"#{cfg.mealie.next_order_list}\" ---"
  puts "  #{result.recipe_items} recipe ingredient(s)"
  puts "  #{result.recurring_count} recurring staple(s)" if result.recurring_count.positive?
  puts "  #{result.manual_count} manual addition(s) consumed" if result.manual_count.positive?
  puts "  #{result.pushed_count} total item(s) pushed"

  if result.unmapped_items.any?
    puts "\n⚠  #{result.unmapped_items.size} unmapped ingredient(s) — run automap to map them:"
    result.unmapped_items.each { |name| puts "     • #{name}" }
    puts "  Auto:   bundle exec ruby main.rb automap"
    puts "  Manual: bundle exec ruby scripts/seed_product_map.rb"
  end

  if result.warnings.any?
    puts "\nWarnings:"
    result.warnings.each { |w| puts "  ⚠  #{w}" }
  end

  ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))
  result.unmapped_items.empty? ? 0 : 1
end

def cmd_automap
  puts '=== Mealie AutoChef — automap (LLM-assisted recipe mapping) ==='

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

  unless cfg.llm.enabled
    puts 'LLM not enabled — set llm.enabled: true in config.yaml'
    return 1
  end

  client = build_client(cfg)
  begin
    client.ping
  rescue StandardError => e
    puts "Cannot reach Mealie: #{e.message}"
    return 1
  end

  history = Autochef::Models::PlanHistory.where(approved: 1).order(created_at: :desc).first
  if history.nil?
    puts 'No approved plan found. Run `main.rb plan` and approve it first.'
    return 1
  end
  puts "Using approved plan id=#{history.id} (week of #{history.week_start})."

  mapper = Autochef::LlmRecipeMapper.new(cfg)
  puts "\nRunning LLM-assisted recipe mapping..."
  result = mapper.map_unmapped(mealie_client: client, plan_history: history)

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
    result.suspicious.each { |s| puts "  ⚠  #{s['ingredient_name']}: #{s['concern']}" }
    puts "  Run: bundle exec ruby scripts/seed_product_map.rb --update"
  end

  if result.new_mapped.empty? && result.pantry_skipped.empty? &&
     result.suspicious.empty? && result.errors.empty?
    puts "\nAll ingredients already mapped — nothing to do."
  end

  if cfg.notify.channel == 'telegram' && !cfg.notify.telegram_bot_token.to_s.empty?
    begin
      Autochef::Notifier.new(cfg, mealie_client: client).send_automap_report(result)
      puts "\nTelegram report sent."
    rescue StandardError => e
      puts "Telegram report failed: #{e.message}"
    end
  end

  result.errors.empty? ? 0 : 1
end

def cmd_build_cart(force: false)
  puts '=== Mealie AutoChef — build-cart (Phase 5) ==='

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

  safety = Autochef::Safety.new(cfg)

  # Kill switch — first thing checked in any ordering flow.
  begin
    safety.check_kill_switch!
  rescue Autochef::Safety::KillSwitchError => e
    puts "HALTED: #{e.message}"
    return 1
  end

  # Require an approved plan so we have a week_start for the idempotency key.
  history = Autochef::Models::PlanHistory.where(approved: 1).order(created_at: :desc).first
  if history.nil?
    puts 'No approved plan found. Run `main.rb plan` and approve it first.'
    return 1
  end

  week_start = history.week_start.to_date
  run_key    = safety.idempotency_key(week_start)
  puts "Run key: #{run_key}"

  # Idempotency — skip if we already built the cart for this week.
  unless force
    begin
      safety.check_idempotency!(run_key)
    rescue Autochef::Safety::IdempotencyError => e
      puts "SKIP: #{e.message}"
      return 0
    end
  end

  # Fetch the current "Next Order" list from Mealie.
  client = build_client(cfg)
  begin
    client.ping
  rescue StandardError => e
    puts "Cannot reach Mealie: #{e.message}"
    puts 'Tip: set MEALIE_URL in .env or run inside Docker.'
    return 1
  end

  list      = client.find_or_create_shopping_list(cfg.mealie.next_order_list)
  full_list = client.shopping_list(list['id'])
  raw_items = full_list['listItems'] || full_list['items'] || []

  if raw_items.empty?
    puts "Next Order list is empty — run `main.rb shop` first."
    return 1
  end

  puts "Found #{raw_items.size} item(s) in Next Order."

  skipped_names = []
  cart_items = raw_items.filter_map do |item|
    result = resolve_cart_item(item)
    if result.nil?
      raw_name = item['note'].to_s.strip
      key = raw_name.downcase.strip.gsub(/\s+/, ' ')
      mapping = Autochef::Models::ProductMap.find_by(key: key)
      skipped_names << raw_name if mapping&.search_term == '__skip__' && !raw_name.empty?
    else
      # Attach the ingredient name for LLM consolidation context.
      result['sources'] = [item['note'].to_s.strip].reject(&:empty?)
    end
    result
  end

  if skipped_names.any?
    puts "\nPantry items assumed on hand (#{skipped_names.size}) — verify stock before pickup:"
    skipped_names.each { |n| puts "  • #{n}" }
    puts "  (Use /add <item> in Telegram if you need to restock any, then send /shop to rebuild.)"
  end

  # Enhancement 1 — consolidate duplicate search terms: sum quantities, collect sources.
  grouped = cart_items.group_by { |i| i['search_term'] }
  merged_terms = grouped.select { |_, items| items.size > 1 }.keys
  cart_items = grouped.map do |_term, items|
    total_qty   = items.sum { |i| (i['default_qty'] || 1).to_i }
    all_sources = items.flat_map { |i| Array(i['sources']) }.uniq
    items.first.merge('default_qty' => total_qty, 'sources' => all_sources)
  end
  if merged_terms.any?
    puts "\nConsolidated #{merged_terms.size} duplicate search term(s) (quantities summed):"
    merged_terms.each { |t| puts "  • #{t}" }
  end

  # Enhancement 2 — LLM quantity rationalization (pack sizes, real-world grocery units).
  if cfg.llm.enabled
    plan_recipes = history.plan.values.map { |e| e['recipe_name'].to_s }.uniq
    consolidator = Autochef::LlmQtyConsolidator.new(cfg)
    puts "\nRunning LLM quantity consolidation..."
    cart_items = consolidator.consolidate(cart_items, plan_recipes: plan_recipes)
  end

  # Build the input payload for cart.py (strip Ruby-only fields like 'sources').
  cart_items_for_py = cart_items.map { |i| i.slice('search_term', 'default_qty', 'pack_unit') }
  input = {
    'run_key'                  => run_key,
    'store_name'               => cfg.store.name,
    'pickup_window_pref'       => cfg.schedule.pickup_window_pref,
    'spending_cap_usd'         => cfg.safety.spending_cap_usd,
    'cart_deviation_alert_pct' => cfg.safety.cart_deviation_alert_pct,
    'dry_run'                  => cfg.safety.dry_run,
    'items'                    => cart_items_for_py
  }

  puts "\nInvoking cart builder (#{cart_items_for_py.size} item(s))..."
  puts "(dry_run: true — cart will be built but no order placed)" if cfg.safety.dry_run

  begin
    result = Autochef::CartClient.build_cart(input)
  rescue Autochef::CartClient::CartBuilderError => e
    puts "Cart builder CRASHED: #{e.message}"
    return 1
  end

  puts "Cart builder status: #{result['status']}"

  case result['status']
  when 'cart_built'
    cart_total = result['cart_total']&.to_f

    # Spending cap (defence-in-depth; cart.py also checks, Ruby checks here for logging).
    begin
      safety.check_spending_cap!(cart_total)
    rescue Autochef::Safety::SpendingCapError => e
      puts "SPENDING CAP EXCEEDED: #{e.message}"
      write_order_history(run_key, history, result.merge('status' => 'aborted'), notes: e.message)
      if cfg.notify.channel == 'telegram' && !cfg.notify.telegram_bot_token.to_s.empty?
        Autochef::Notifier.new(cfg, mealie_client: client).send_cart_aborted(e.message)
      end
      return 1
    end

    dev_warning = safety.deviation_warning(result['est_total']&.to_f, cart_total)
    result['deviation_warning'] = dev_warning if dev_warning

    record = write_order_history(run_key, history, result)
    puts "Order history saved (id=#{record.id})."
    puts "Screenshot: #{result['screenshot_path']}" if result['screenshot_path']

    if (pp = result['previous_purchases_stats'])
      puts "Previous purchases: #{pp['matched']}/#{pp['available']} matched " \
           "(#{pp['search_adds']} via search)"
    end

    if dev_warning
      puts "\nWARNING: #{dev_warning}"
    end

    if result['flagged_items']&.any?
      puts "\n#{result['flagged_items'].size} item(s) flagged (out of stock / not found):"
      result['flagged_items'].each { |item| puts "  • #{item}" }
    end

    if cfg.notify.channel == 'telegram' && !cfg.notify.telegram_bot_token.to_s.empty?
      Autochef::Notifier.new(cfg, mealie_client: client)
                        .send_cart_ready(result, dry_run: cfg.safety.dry_run,
                                         deviation_warning: dev_warning,
                                         skipped_items: skipped_names)
      puts "Telegram notification sent."
    end

  when 'session_expired'
    reason = result['abort_reason'] || 'session_expired'
    puts "Food Lion session issue (#{reason}) — cart build paused, waiting for manual refresh."
    # Don't write order_history for session_expired — it's an interrupted build, not a completed order.
    if cfg.notify.channel == 'telegram' && !cfg.notify.telegram_bot_token.to_s.empty?
      Autochef::Notifier.new(cfg, mealie_client: client).send_session_expired_alert(reason)
    end
    return 1

  when 'aborted'
    reason = result['abort_reason'] || 'Unknown abort reason'
    puts "Cart build aborted: #{reason}"
    write_order_history(run_key, history, result, notes: reason)
    if cfg.notify.channel == 'telegram' && !cfg.notify.telegram_bot_token.to_s.empty?
      Autochef::Notifier.new(cfg, mealie_client: client).send_cart_aborted(reason)
    end
    return 1

  else
    puts "Unexpected status from cart builder: #{result['status'].inspect}"
    return 1
  end

  ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))
  0
end

# Resolve a Mealie shopping list item to a cart input hash for cart.py.
# Tries to look up the product_map by the item's normalized display name.
# Falls back to the item's own name + quantity if unmapped.
def resolve_cart_item(mealie_item)
  raw_name = mealie_item['note'].to_s.strip
  key      = raw_name.downcase.strip.gsub(/\s+/, ' ')
  mapping  = Autochef::Models::ProductMap.find_by(key: key)

  return nil if mapping&.search_term == '__skip__'

  if mapping
    {
      'search_term' => mapping.search_term.to_s.empty? ? raw_name : mapping.search_term,
      'default_qty' => (mapping.default_qty || 1).to_i,
      'pack_unit'   => mapping.pack_unit
    }
  else
    qty  = mealie_item['quantity']&.to_f || 1.0
    unit = mealie_item.dig('unit', 'name')
    {
      'search_term' => raw_name,
      'default_qty' => [qty.ceil, 1].max,
      'pack_unit'   => unit
    }
  end
end

# Persist cart builder output to order_history. Returns the saved record.
# If a row already exists for run_key (force-rebuild), it's updated in-place.
def write_order_history(run_key, plan_history, cart_result, notes: nil)
  record = Autochef::Models::OrderHistory.for_run_key(run_key).first ||
           Autochef::Models::OrderHistory.new(run_key: run_key)

  record.week_start   = plan_history.week_start
  record.items_json   = (cart_result['items'] || []).to_json
  record.est_total    = cart_result['est_total']&.to_f
  record.actual_total = cart_result['cart_total']&.to_f
  record.status       = cart_result['status']
  record.pickup_slot  = cart_result['pickup_slot']
  record.notes        = [notes, cart_result['abort_reason']].compact.join('; ')
  record.save!
  record
end

def cmd_feedback(force: false)
  puts '=== Mealie AutoChef — feedback (Phase 6) ==='

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

  order_record = Autochef::Models::OrderHistory.order(created_at: :desc).first
  if order_record.nil?
    puts 'No order_history rows found. Build a cart first with `main.rb build-cart`.'
    return 1
  end

  puts "Using order_history id=#{order_record.id} (week of #{order_record.week_start}, " \
       "status: #{order_record.status})."

  # Try to reach Mealie for tag updates (graceful degradation if unreachable).
  mealie_client = nil
  begin
    client = build_client(cfg)
    client.ping
    mealie_client = client
    puts 'Mealie reachable — tag_weight updates enabled.'
  rescue StandardError => e
    puts "Mealie unreachable (#{e.message.slice(0, 80)}) — will update recipe_stats only."
  end

  applier = Autochef::FeedbackApplier.new(mealie_client: mealie_client)

  begin
    result = applier.apply(order_record, force: force)
  rescue StandardError => e
    puts "Feedback apply FAILED: #{e.message}"
    return 1
  end

  if result.already_applied
    puts 'Feedback already applied for this order. Pass --force to re-apply.'
    return 0
  end

  puts "\nFeedback applied:"
  puts "  #{result.cooked_count} recipe(s) — times_cooked incremented, last_cooked updated"

  if mealie_client
    puts "  #{result.tag_updates} recipe(s) — tag_weights nudged"
    puts "  #{result.tag_skipped} recipe(s) skipped (tag fetch failed)" if result.tag_skipped.positive?
  else
    puts '  (tag_weight updates skipped — Mealie unreachable)'
  end

  ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))
  0
end

def cmd_budget
  puts '=== Mealie AutoChef — budget (Phase 6) ==='

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

  cap = cfg.safety.spending_cap_usd.to_f
  now = Date.today

  all_rows = Autochef::Models::OrderHistory
             .where.not(actual_total: nil)
             .order(week_start: :asc)
             .to_a

  if all_rows.empty?
    puts 'No completed orders with actual totals recorded yet.'
    return 0
  end

  month_start = Date.new(now.year, now.month, 1)
  year_start  = Date.new(now.year, 1, 1)

  this_month = all_rows.select { |r| r.week_start.to_date >= month_start }
  this_year  = all_rows.select { |r| r.week_start.to_date >= year_start }

  month_total = this_month.sum { |r| r.actual_total.to_f }
  year_total  = this_year.sum  { |r| r.actual_total.to_f }

  puts ''
  puts "Spending cap: $#{'%.2f' % cap}"
  puts "This month (#{now.strftime('%B %Y')}): $#{'%.2f' % month_total} " \
       "(#{this_month.size} order(s))"
  puts "YTD (#{now.year}): $#{'%.2f' % year_total} (#{this_year.size} order(s))"

  puts ''
  puts 'Weekly breakdown:'
  all_rows.each do |r|
    total_str = '$%.2f' % r.actual_total.to_f
    over_flag = r.actual_total.to_f > cap ? '  *** OVER CAP ***' : ''
    puts "  Week of #{r.week_start}: #{total_str}#{over_flag}"
  end

  over_cap = all_rows.select { |r| r.actual_total.to_f > cap }
  if over_cap.any?
    puts ''
    puts "#{over_cap.size} week(s) exceeded spending cap ($#{'%.2f' % cap})."
    return 1
  end

  0
end

def cmd_backup
  puts '=== Mealie AutoChef — backup (Phase 6) ==='

  begin
    cfg = Autochef::Config.load
  rescue StandardError => e
    puts "Config load FAILED: #{e.message}"
    return 1
  end

  errors = []

  # 1. SQLite dump: copy autochef.db → data/backups/autochef_YYYYMMDD.db
  db_path    = File.join(Autochef::REPO_ROOT, 'data', 'autochef.db')
  backup_dir = File.join(Autochef::REPO_ROOT, 'data', 'backups')

  if File.exist?(db_path)
    FileUtils.mkdir_p(backup_dir)
    timestamp   = Date.today.strftime('%Y%m%d')
    backup_path = File.join(backup_dir, "autochef_#{timestamp}.db")
    FileUtils.cp(db_path, backup_path)
    puts "SQLite backed up: #{backup_path} (#{File.size(backup_path)} bytes)"
  else
    msg = "autochef.db not found at #{db_path} — nothing to back up."
    puts "WARNING: #{msg}"
    errors << msg
  end

  # 2. Mealie backup: POST /api/admin/backups
  begin
    client = build_client(cfg)
    client.ping
    client.trigger_backup
    puts 'Mealie backup triggered via API.'
  rescue StandardError => e
    msg = "Mealie backup failed: #{e.message.slice(0, 200)}"
    puts msg
    errors << msg
  end

  ping_uptime_kuma(ENV.fetch('UPTIME_KUMA_PUSH_URL', ''))
  errors.empty? ? 0 : 1
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
  when 'shop'
    cmd_shop
  when 'automap'
    cmd_automap
  when 'build-cart'
    cmd_build_cart(force: ARGV.include?('--force'))
  when 'feedback'
    cmd_feedback(force: ARGV.include?('--force'))
  when 'budget'
    cmd_budget
  when 'backup'
    cmd_backup
  when nil
    puts 'Usage: ruby main.rb <check|sync|serve|plan|shop|automap|build-cart [--force]|feedback [--force]|budget|backup>'
    1
  else
    puts "Unknown command: #{command}"
    1
  end
end

exit(main) if __FILE__ == $PROGRAM_NAME
