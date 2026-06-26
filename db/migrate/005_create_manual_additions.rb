# frozen_string_literal: true

class CreateManualAdditions < ActiveRecord::Migration[7.1]
  def change
    create_table :manual_additions do |t|
      t.string :name, null: false
      t.float :quantity, default: 1
      t.string :unit
      t.timestamp :added_at, default: -> { "CURRENT_TIMESTAMP" }
      t.boolean :consumed, default: false
    end
  end
end
