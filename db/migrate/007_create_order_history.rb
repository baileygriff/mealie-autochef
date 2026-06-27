# frozen_string_literal: true

class CreateOrderHistory < ActiveRecord::Migration[7.1]
  def change
    create_table :order_history do |t|
      t.date :week_start
      t.text :items_json
      t.float :est_total
      t.float :actual_total
      t.string :status # 'cart_built' | 'approved' | 'placed' | 'aborted'
      t.string :pickup_slot
      t.string :run_key # idempotency key
      t.text :notes
      t.timestamp :created_at, default: -> { 'CURRENT_TIMESTAMP' }
    end

    add_index :order_history, :week_start
    add_index :order_history, :run_key
  end
end
