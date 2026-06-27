# frozen_string_literal: true

module Autochef
  module Models
    # Tracks per-recipe planning/cooking history and the deterministic
    # preference score (see scoring.rb, Phase 2). recipe_id is the Mealie
    # recipe's own id/slug — not an autochef-generated id.
    class RecipeStat < ActiveRecord::Base
      self.table_name = 'recipe_stats'
      self.primary_key = 'recipe_id'
    end
  end
end
