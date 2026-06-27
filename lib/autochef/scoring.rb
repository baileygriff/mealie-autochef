# frozen_string_literal: true

require_relative 'models/recipe_stat'
require_relative 'models/tag_weight'

module Autochef
  # Deterministic preference scorer for the eligible recipe pool.
  #
  # Formula (all weights from config.selection.scoring_weights):
  #   score = w_rating       * normalized_rating(avg_rating)
  #         + w_tag_affinity  * mean(tag_weights for recipe tags)
  #         - w_recency       * recency_factor(last_cooked)
  #         - w_swap          * times_swapped_out
  #         + w_nutrition_fit * protein_fit(recipe)   # if nutrition.enabled
  #
  # Protein-per-serving is sourced from Mealie's nutritionData if present,
  # falling back to a tag-based heuristic (protein:* tags).
  class Scorer
    # Protein estimates (g/serving) by protein:* tag for heuristic fallback.
    PROTEIN_TAG_ESTIMATES = {
      'protein:beef' => 35,
      'protein:chicken' => 35,
      'protein:pork' => 30,
      'protein:turkey' => 33,
      'protein:fish' => 30,
      'protein:seafood' => 25,
      'protein:lamb' => 28,
      'protein:egg' => 12,
      'protein:tofu' => 10,
      'protein:legumes' => 12,
      'protein:plant' => 10
    }.freeze

    def initialize(cfg)
      @weights   = cfg.selection.scoring_weights
      @nutrition = cfg.nutrition
    end

    # Score a single recipe hash (from eligible_pool) against its RecipeStat row.
    # Returns a Float. Recipes with no stat row get a neutral score.
    #
    # recipe     — hash from MealieClient#eligible_pool (has "id", "tags", etc.)
    # stat       — Autochef::Models::RecipeStat or nil
    # tag_weights — hash { tag_name => weight } from the tag_weights table
    # nutrition_data — hash with "protein" key (g per full recipe), or nil
    # base_servings  — Integer, from the full recipe fetch (or config default)
    def score(recipe, stat:, tag_weights:, nutrition_data: nil, base_servings: 2)
      s = 0.0
      s += @weights.rating * rating_component(stat)
      s += @weights.tag_affinity * tag_affinity_component(recipe, tag_weights)
      s -= @weights.recency_penalty * recency_component(stat)
      s -= @weights.swap_penalty    * swap_component(stat)
      s += @weights.nutrition_fit   * protein_component(recipe, nutrition_data, base_servings) if @nutrition.enabled
      s
    end

    # Compute and persist scores for all stats in the DB, given a recipe pool.
    # recipe_map: { recipe_id => recipe_hash }
    # nutrition_map: { recipe_id => { nutrition_data:, base_servings: } }
    def update_scores!(recipe_map, nutrition_map: {})
      tag_weights = load_tag_weights

      recipe_map.each do |recipe_id, recipe|
        stat = Models::RecipeStat.find_or_initialize_by(recipe_id: recipe_id)
        nd   = nutrition_map.dig(recipe_id, :nutrition_data)
        bs   = nutrition_map.dig(recipe_id, :base_servings) || 2
        stat.score = score(recipe, stat: stat, tag_weights: tag_weights,
                                   nutrition_data: nd, base_servings: bs)
        stat.save!
      end
    end

    private

    # 0–1 normalized from a 1–5 Mealie rating. nil rating → 0.5 (neutral).
    def rating_component(stat)
      return 0.5 if stat.nil? || stat.avg_rating.nil?

      [(stat.avg_rating.to_f - 1.0) / 4.0, 0.0].max.clamp(0.0, 1.0)
    end

    # Mean of tag_weights for all tags on the recipe. Unknown tags → 0.
    def tag_affinity_component(recipe, tag_weights)
      tags = extract_tag_names(recipe)
      return 0.0 if tags.empty?

      weights = tags.map { |t| tag_weights.fetch(t, 0.0) }
      weights.sum / weights.size.to_f
    end

    # Continuous decay: 1.0 if cooked this week, approaching 0 asymptotically.
    # Recipes beyond repeat_avoidance_weeks are already filtered before scoring,
    # so this soft penalty covers the "recently cooked but eligible" range.
    def recency_component(stat)
      return 0.0 if stat.nil? || stat.last_cooked.nil?

      weeks_ago = (Date.today - stat.last_cooked.to_date).to_f / 7.0
      return 0.0 if weeks_ago <= 0

      1.0 / weeks_ago
    end

    # Raw count of times this recipe was swapped out at approval. No cap —
    # frequently rejected recipes naturally sink to the bottom.
    def swap_component(stat)
      return 0.0 if stat.nil?

      stat.times_swapped_out.to_f
    end

    # Protein-forward fit: how close is protein/serving to the target?
    # Returns 0–1; 1.0 means at-or-above target, decays linearly below.
    def protein_component(recipe, nutrition_data, base_servings)
      target  = @nutrition.target_protein_per_serving_g.to_f
      protein = protein_per_serving(recipe, nutrition_data, base_servings)
      return 0.0 if protein.nil?

      [protein / target, 1.0].min
    end

    # Resolve protein/serving: Mealie nutritionData first, tag heuristic fallback.
    def protein_per_serving(recipe, nutrition_data, base_servings)
      if nutrition_data.is_a?(Hash)
        raw = nutrition_data['protein'] || nutrition_data[:protein]
        if raw.to_f.positive?
          servings = [base_servings.to_i, 1].max
          return raw.to_f / servings
        end
      end

      # Tag-based heuristic
      tags = extract_tag_names(recipe)
      tag_protein = tags.filter_map { |t| PROTEIN_TAG_ESTIMATES[t] }.max
      tag_protein&.to_f
    end

    def extract_tag_names(recipe)
      (recipe['tags'] || []).map { |t| t['name'].to_s }
    end

    def load_tag_weights
      Models::TagWeight.all.to_h do |tw|
        [tw.tag, tw.weight.to_f]
      end
    end
  end
end
