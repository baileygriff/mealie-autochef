# frozen_string_literal: true

class CreateRecipeStats < ActiveRecord::Migration[7.1]
  def change
    create_table :recipe_stats, id: false do |t|
      t.string :recipe_id, primary_key: true, null: false
      t.integer :times_planned, default: 0
      t.integer :times_cooked, default: 0
      t.integer :times_swapped_out, default: 0
      t.date :last_planned
      t.date :last_cooked
      t.float :avg_rating
      t.float :score, default: 0
      t.timestamp :updated_at, default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
