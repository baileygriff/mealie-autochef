# frozen_string_literal: true

class AddFeedbackAppliedToOrderHistory < ActiveRecord::Migration[7.1]
  def change
    add_column :order_history, :feedback_applied, :boolean, default: false, null: false
  end
end
