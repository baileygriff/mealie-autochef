# frozen_string_literal: true

class CreateTagWeights < ActiveRecord::Migration[7.1]
  def change
    create_table :tag_weights, id: false do |t|
      t.string :tag, primary_key: true, null: false
      t.float :weight, default: 0
      t.timestamp :updated_at, default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
