# frozen_string_literal: true

class CreatePlanHistory < ActiveRecord::Migration[7.1]
  def change
    create_table :plan_history do |t|
      t.date :week_start
      t.text :plan_json # {date: {recipe_id, servings, meal_type, rationale}}
      t.boolean :approved, default: false
      t.text :swaps_json
      t.timestamp :created_at, default: -> { 'CURRENT_TIMESTAMP' }
    end

    add_index :plan_history, :week_start
  end
end
