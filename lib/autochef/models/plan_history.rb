# frozen_string_literal: true

require "json"

module Autochef
  module Models
    # One row per generated weekly plan draft. plan_json holds the
    # {date: {recipe_id, servings, meal_type, rationale}} structure the LLM
    # planner (Phase 2) produces; swaps_json logs what got swapped during
    # approval (Phase 3) — the strongest preference signal the scorer gets.
    class PlanHistory < ActiveRecord::Base
      self.table_name = "plan_history"

      # Convenience accessors so callers don't hand-roll JSON.parse/generate
      # everywhere. Kept intentionally thin — no business logic here.
      def plan
        plan_json.present? ? JSON.parse(plan_json) : {}
      end

      def plan=(hash)
        self.plan_json = hash.to_json
      end

      def swaps
        swaps_json.present? ? JSON.parse(swaps_json) : {}
      end

      def swaps=(hash)
        self.swaps_json = hash.to_json
      end
    end
  end
end
