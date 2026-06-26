# frozen_string_literal: true

module Autochef
  module Models
    # An item added via /add in Telegram (Phase 3), outside the normal meal
    # plan. Written here AND pushed to the Mealie "Next Order" list;
    # `consumed` marks it as already folded into a built cart.
    class ManualAddition < ActiveRecord::Base
      self.table_name = "manual_additions"

      validates :name, presence: true

      scope :pending, -> { where(consumed: false) }
    end
  end
end
