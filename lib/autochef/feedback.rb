# frozen_string_literal: true

require 'date'
require_relative 'models/order_history'
require_relative 'models/plan_history'
require_relative 'models/recipe_stat'
require_relative 'models/tag_weight'

module Autochef
  # Closes the preference-learning loop after a week completes.
  #
  # What it does:
  #   1. Increments times_cooked + updates last_cooked in recipe_stats for every
  #      recipe in the approved plan (the ones you actually cooked).
  #   2. Nudges tag_weights up (+0.1) for cooked recipes' tags and down (-0.2)
  #      for swapped-out recipes' tags — requires a live Mealie connection; skips
  #      gracefully if Mealie is unreachable.
  #   3. Marks the order_history row as feedback_applied to prevent double-runs.
  #
  # Note: times_swapped_out is already incremented at swap-time by notify.rb's
  # callback_swap. This class does NOT re-increment it.
  class FeedbackApplier
    TAG_COOKED_DELTA  = 0.1
    TAG_SWAPPED_DELTA = 0.2  # subtracted

    Result = Struct.new(:cooked_count, :tag_updates, :tag_skipped, :already_applied,
                        keyword_init: true)

    def initialize(mealie_client: nil)
      @mealie = mealie_client
    end

    # Apply feedback for the given OrderHistory row.
    # Optionally accepts a PlanHistory override; otherwise matches by week_start.
    # Returns a Result struct.
    def apply(order_record, plan_history: nil, force: false)
      if order_record.feedback_applied && !force
        return Result.new(cooked_count: 0, tag_updates: 0, tag_skipped: 0, already_applied: true)
      end

      plan_history ||= find_plan_for(order_record)
      raise "No approved plan found for week_start=#{order_record.week_start}" unless plan_history

      plan  = plan_history.plan
      swaps = plan_history.swaps

      cooked_count = update_times_cooked(plan)
      tag_updates, tag_skipped = update_tag_weights(plan, swaps)

      order_record.update!(feedback_applied: true)

      Result.new(cooked_count: cooked_count, tag_updates: tag_updates,
                 tag_skipped: tag_skipped, already_applied: false)
    end

    private

    # 1. Increment times_cooked + set last_cooked for each planned recipe.
    def update_times_cooked(plan)
      count = 0
      plan.each do |date_str, entry|
        recipe_id = entry['recipe_id']
        next if recipe_id.to_s.empty?

        stat = Models::RecipeStat.find_or_initialize_by(recipe_id: recipe_id)
        stat.times_cooked = stat.times_cooked.to_i + 1
        stat.last_cooked  = Date.parse(date_str)
        stat.save!
        count += 1
      end
      count
    end

    # 2. Nudge tag_weights based on cooked vs swapped recipes.
    # Returns [updates_applied, recipes_skipped].
    def update_tag_weights(plan, swaps)
      return [0, 0] unless @mealie

      updates = 0
      skipped = 0

      plan.each_value do |entry|
        recipe_id = entry['recipe_id']
        next if recipe_id.to_s.empty?

        tags = fetch_tags(recipe_id)
        if tags
          nudge_tags(tags, +TAG_COOKED_DELTA)
          updates += 1
        else
          skipped += 1
        end
      end

      swaps.each_value do |swapped_ids|
        Array(swapped_ids).each do |swapped_id|
          next if swapped_id.to_s.empty?

          tags = fetch_tags(swapped_id)
          if tags
            nudge_tags(tags, -TAG_SWAPPED_DELTA)
            updates += 1
          else
            skipped += 1
          end
        end
      end

      [updates, skipped]
    end

    def fetch_tags(recipe_id)
      recipe = @mealie.recipe(recipe_id)
      (recipe['tags'] || []).map { |t| t['name'].to_s }.reject(&:empty?)
    rescue StandardError => e
      warn "FeedbackApplier: could not fetch tags for #{recipe_id}: #{e.message}"
      nil
    end

    def nudge_tags(tags, delta)
      tags.each do |tag|
        tw        = Models::TagWeight.find_or_initialize_by(tag: tag)
        tw.weight = tw.weight.to_f + delta
        tw.save!
      end
    end

    def find_plan_for(order_record)
      # Prefer the approved plan that matches this order's week_start.
      plan = Models::PlanHistory
             .where(approved: 1, week_start: order_record.week_start)
             .order(created_at: :desc)
             .first
      # Fall back to the most recent approved plan (covers older order_history rows).
      plan || Models::PlanHistory.where(approved: 1).order(created_at: :desc).first
    end
  end
end
