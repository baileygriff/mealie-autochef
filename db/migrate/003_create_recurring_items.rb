# frozen_string_literal: true

class CreateRecurringItems < ActiveRecord::Migration[7.1]
  def change
    create_table :recurring_items do |t|
      t.string :name, null: false
      t.string :product_ref # -> product_map.key
      t.float :quantity, default: 1
      t.string :unit
      t.string :cadence_type, null: false # 'every_order' | 'every_n_orders' | 'every_n_days'
      t.integer :cadence_value, default: 1
      t.date :last_added
      t.boolean :active, default: true
    end
  end
end
