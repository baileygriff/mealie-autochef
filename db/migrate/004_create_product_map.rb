# frozen_string_literal: true

class CreateProductMap < ActiveRecord::Migration[7.1]
  def change
    create_table :product_map, id: false do |t|
      t.string :key, primary_key: true, null: false # normalized mealie food name/id
      t.string :display_name
      t.string :search_term # what to search in Food Lion
      t.string :preferred_product_id # Food Lion/Instacart product id if known
      t.float :pack_size # e.g. 16
      t.string :pack_unit # 'oz' | 'lb' | 'ct'
      t.integer :default_qty, default: 1 # packs to buy by default
      t.string :rounding, default: 'up' # recipe qty -> packs
      t.text :substitution_notes
      t.timestamp :updated_at, default: -> { 'CURRENT_TIMESTAMP' }
    end
  end
end
