# frozen_string_literal: true

require 'date'
require_relative 'models/recurring_item'
require_relative 'models/plan_history'

module Autochef
  # Determines which recurring staple items are due for the current order
  # and marks them as added once injected into the shopping list.
  #
  # Cadence types:
  #   every_order    — always due
  #   every_n_orders — due when N approved plans have run since last_added
  #   every_n_days   — due when N days have elapsed since last_added
  class RecurringInjector
    def initialize(cfg)
      @cfg = cfg
    end

    # Returns array of active RecurringItem records that are due as of as_of_date.
    def due_items(as_of_date: Date.today)
      Models::RecurringItem.active.select { |item| due?(item, as_of_date) }
    end

    # Update last_added on all given items. Call after successfully pushing them
    # to the shopping list.
    def mark_added!(items, as_of_date: Date.today)
      items.each { |item| item.update!(last_added: as_of_date) }
    end

    private

    def due?(item, as_of_date)
      return true if item.last_added.nil?

      last = item.last_added.to_date

      case item.cadence_type
      when 'every_order'
        true
      when 'every_n_orders'
        # Count approved plans since item was last added as a proxy for order count.
        plans_since = Models::PlanHistory
                      .where(approved: 1)
                      .where('created_at > ?', last.to_time)
                      .count
        plans_since >= item.cadence_value.to_i
      when 'every_n_days'
        (as_of_date - last).to_i >= item.cadence_value.to_i
      else
        false
      end
    end
  end
end
