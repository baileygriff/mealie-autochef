# frozen_string_literal: true

require "json"

module Autochef
  module Models
    # One row per cart-build run. run_key is the idempotency key (Phase 5
    # safety.rb) — re-running the same week's build should reconcile against
    # an existing row, not double-order.
    class OrderHistory < ActiveRecord::Base
      self.table_name = "order_history"

      validates :status, inclusion: { in: %w[cart_built approved placed aborted] }, allow_nil: true

      def items
        items_json.present? ? JSON.parse(items_json) : []
      end

      def items=(arr)
        self.items_json = arr.to_json
      end

      scope :for_run_key, ->(key) { where(run_key: key) }
    end
  end
end
