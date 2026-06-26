# frozen_string_literal: true

module Autochef
  module Models
    # A staple item injected into the cart on a cadence (every order, every
    # N orders, every N days) — see recurring.rb (Phase 4). product_ref
    # points at ProductMap#key when known.
    class RecurringItem < ActiveRecord::Base
      self.table_name = "recurring_items"

      validates :name, presence: true
      validates :cadence_type, inclusion: { in: %w[every_order every_n_orders every_n_days] }

      scope :active, -> { where(active: true) }
    end
  end
end
