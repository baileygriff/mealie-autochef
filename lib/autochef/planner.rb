# frozen_string_literal: true

require 'date'
require_relative 'models/recipe_stat'
require_relative 'models/plan_history'

module Autochef
  # Deterministic cook-day scheduler.
  #
  # Week anchor: the pickup_day (Sunday by default). week_start is always the
  # date of the configured pickup_day, and WEEKDAY_ORDER is Sunday-first so
  # date offsets from week_start are correct for a Sun–Sat planning week.
  #
  # Algorithm:
  #   1. Split cook days into "constrained" (precede a leftover day, need a
  #      makes-leftovers recipe) and "free".
  #   2. Pick makes-leftovers recipes for constrained days; assign sorted by
  #      perishability ascending vs. cook date ascending.
  #   3. Pick remaining recipes for free days (+ constrained days that had no
  #      makes-leftovers available); assign sorted by perishability vs. date.
  #   4. Flag perishability violations (shelf_life < days_until_cook).
  class Planner
    # Sunday-first so week_start (the pickup Sunday) maps to offset 0.
    WEEKDAY_ORDER = %w[Sun Mon Tue Wed Thu Fri Sat].freeze

    WeekPlan = Struct.new(
      :week_start,    # Date — the pickup Sunday of the target week
      :assignments,   # Array<Assignment>
      :warnings,      # Array<String>
      keyword_init: true
    )

    Assignment = Struct.new(
      :date,            # Date
      :day_name,        # "Sun", "Mon", …
      :recipe_id,       # String (Mealie id)
      :recipe_name,     # String
      :servings,        # Integer
      :meal_type,       # "dinner" | "lunch"
      :makes_leftovers, # Boolean
      :perishability,   # Integer (min shelf_life_days among non-on-hand ingredients)
      :rationale,       # String (filled in by LlmPlanner; "" for deterministic)
      keyword_init: true
    )

    def initialize(cfg)
      @cfg = cfg
    end

    # Build a deterministic plan for the week whose pickup day is week_start.
    #
    # pool             — Array of recipe hashes from MealieClient#eligible_pool,
    #                    each decorated with "perishability" (Integer).
    # scored_ids       — { recipe_id => Float } from Scorer. Missing → 0.
    # layout_overrides — { Date => DayPrefs } from week prefs form — overrides meal_type per day.
    # servings_overrides — { Date => Integer } — per-day servings from week prefs.
    #
    # Returns a WeekPlan.
    def plan(pool:, scored_ids:, week_start: next_week_start,
             layout_overrides: {}, servings_overrides: {})
      warnings = []
      layout   = @cfg.meals.week_layout

      # 1. Cook days and their dates, in calendar order.
      cook_dates = dates_of_type(layout, 'cook', week_start)

      # Apply layout_overrides: remove skipped days, reclassify overridden types.
      if layout_overrides.any?
        cook_dates.reject! do |d|
          override = layout_overrides[d]
          override && override.meal_type.to_s == 'skip'
        end
      end

      # Dates that immediately precede a leftover day → need makes-leftovers recipe.
      leftover_dates       = dates_of_type(layout, 'leftover', week_start).to_set
      needs_leftovers_set  = cook_dates.select { |d| leftover_dates.include?(d + 1) }.to_set

      constrained_dates, free_dates = cook_dates.partition { |d| needs_leftovers_set.include?(d) }

      # 2. Hard-filter: repeat avoidance.
      avoid_before = week_start - (@cfg.selection.repeat_avoidance_weeks * 7)
      eligible     = pool.reject { |r| recently_planned?(r['id'], since: avoid_before) }

      if eligible.empty?
        warnings << 'No eligible recipes after repeat-avoidance filter ' \
                    "(#{@cfg.selection.repeat_avoidance_weeks}-week window). Falling back to full pool."
        eligible = pool
      end

      # 3. Score-sort + variety tracker.
      eligible  = eligible.sort_by { |r| -(scored_ids[r['id']] || 0.0) }
      variety   = VarietyTracker.new(@cfg.selection.variety)
      used_ids  = Set.new
      meal_types = @cfg.meals.meal_types
      default_servings = @cfg.meals.default_servings
      pickup_date = week_start

      assignments = []

      # 4a. Constrained days: try to pick a makes-leftovers recipe each.
      #     Sort constrained_dates earliest first; sort makes-leftovers candidates
      #     by perishability ascending so the most perishable goes earliest.
      makes_leftovers_pool = eligible.select { |r| tag?(r, 'makes-leftovers') }
      constrained_unmet    = [] # dates where makes-leftovers constraint couldn't be met

      constrained_dates.sort.each do |date|
        meal_types.each do |meal_type|
          recipe = pick_one(makes_leftovers_pool, used_ids: used_ids, variety: variety)
          if recipe
            record_pick(recipe, used_ids, variety)
            servings = servings_overrides[date] || default_servings
            assignments << build_assignment(recipe, date: date, servings: servings,
                                                    meal_type: meal_type)
          else
            warnings << "#{fmt_date(date)}: no makes-leftovers recipe available " \
                        "— leftover day #{fmt_date(date + 1)} may not be covered. " \
                        'Will fill from general pool.'
            constrained_unmet << [date, meal_type]
          end
        end
      end

      # 4b. Free days + unmet constrained days: fill with remaining eligible recipes,
      #     perishability-sorted vs. date-sorted.
      remaining_eligible = eligible.reject { |r| used_ids.include?(r['id']) }
                                   .select { |r| variety.allowed?(r) }

      open_slots = (free_dates.sort.flat_map { |d| meal_types.map { |mt| [d, mt] } } +
                    constrained_unmet).sort_by { |d, _mt| d }

      recipes_by_perishability = remaining_eligible.sort_by { |r| r['perishability'] || 365 }

      open_slots.each_with_index do |(date, meal_type), i|
        recipe = recipes_by_perishability[i]
        if recipe.nil?
          warnings << "#{fmt_date(date)}: no eligible recipe available (#{meal_type}); pool exhausted."
          next
        end
        record_pick(recipe, used_ids, variety)
        servings = servings_overrides[date] || default_servings
        assignments << build_assignment(recipe, date: date, servings: servings,
                                                meal_type: meal_type)
      end

      # 5. Sort final assignments by date.
      assignments.sort_by!(&:date)

      # 6. Flag perishability violations.
      assignments.each do |a|
        days_until_cook = (a.date - pickup_date).to_i
        next if a.perishability >= days_until_cook

        warnings << "#{a.day_name} #{fmt_date(a.date)}: '#{a.recipe_name}' has " \
                    "perishability #{a.perishability}d but won't be cooked until " \
                    "#{days_until_cook}d after pickup."
      end

      WeekPlan.new(week_start: week_start, assignments: assignments, warnings: warnings)
    end

    private

    def dates_of_type(layout, type, week_start)
      WEEKDAY_ORDER.filter_map do |day_name|
        val = layout[day_name.to_sym] || layout[day_name]
        next unless val.to_s == type

        date_for_day(week_start, day_name)
      end
    end

    def date_for_day(week_start, day_name)
      offset = WEEKDAY_ORDER.index(day_name)
      return nil if offset.nil?

      week_start + offset
    end

    # Next occurrence of the configured pickup_day (the week anchor).
    def next_week_start
      pickup_name = @cfg.schedule.pickup_day
      pickup_wday = WEEKDAY_ORDER.index(pickup_name)
      return Date.today if pickup_wday.nil?

      # Ruby: wday 0=Sun,1=Mon,...,6=Sat. WEEKDAY_ORDER: 0=Sun,1=Mon,...,6=Sat — same.
      today  = Date.today
      offset = (pickup_wday - today.wday) % 7
      offset = 7 if offset.zero? # never return today; plan for the next occurrence
      today + offset
    end

    def recently_planned?(recipe_id, since:)
      stat = Models::RecipeStat.find_by(recipe_id: recipe_id)
      return false if stat.nil? || stat.last_planned.nil?

      stat.last_planned.to_date >= since
    end

    def pick_one(pool, used_ids:, variety:)
      pool.find { |r| !used_ids.include?(r['id']) && variety.allowed?(r) }
    end

    def record_pick(recipe, used_ids, variety)
      used_ids.add(recipe['id'])
      variety.record(recipe)
    end

    def build_assignment(recipe, date:, servings:, meal_type:)
      Assignment.new(
        date: date,
        day_name: date.strftime('%a'),
        recipe_id: recipe['id'],
        recipe_name: recipe['name'],
        servings: servings,
        meal_type: meal_type,
        makes_leftovers: tag?(recipe, 'makes-leftovers'),
        perishability: recipe['perishability'] || 365,
        rationale: ''
      )
    end

    def tag?(recipe, tag_name)
      (recipe['tags'] || []).any? { |t| t['name'].to_s.casecmp?(tag_name) }
    end

    def fmt_date(date)
      date.strftime('%a %b %-d')
    end

    class VarietyTracker
      def initialize(variety_cfg)
        @max_cuisine = variety_cfg.max_same_cuisine_per_week
        @max_protein = variety_cfg.max_same_protein_per_week
        @cuisine_counts = Hash.new(0)
        @protein_counts = Hash.new(0)
      end

      def allowed?(recipe)
        cuisines = tags_of_type(recipe, 'cuisine')
        proteins = tags_of_type(recipe, 'protein')
        cuisines.all? { |c| @cuisine_counts[c] < @max_cuisine } &&
          proteins.all? { |p| @protein_counts[p] < @max_protein }
      end

      def record(recipe)
        tags_of_type(recipe, 'cuisine').each { |c| @cuisine_counts[c] += 1 }
        tags_of_type(recipe, 'protein').each { |p| @protein_counts[p] += 1 }
      end

      private

      def tags_of_type(recipe, prefix)
        (recipe['tags'] || []).map { |t| t['name'].to_s }.select { |n| n.start_with?("#{prefix}:") }
      end
    end
  end
end
