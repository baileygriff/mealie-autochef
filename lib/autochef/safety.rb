# frozen_string_literal: true

require_relative 'models/order_history'

module Autochef
  # Safety gate for ordering flows. Every cart-build run must pass these checks
  # before any browser automation begins. Mirrors section 9 of the spec.
  #
  # Usage:
  #   safety = Safety.new(cfg)
  #   safety.check_kill_switch!         # raises KillSwitchError if data/PAUSE exists
  #   safety.check_idempotency!(key)    # raises IdempotencyError if already built this week
  #   safety.check_spending_cap!(total) # raises SpendingCapError if total > cap
  #   msg = safety.deviation_warning(est, actual)  # returns String or nil
  class Safety
    class KillSwitchError  < StandardError; end
    class SpendingCapError < StandardError; end
    class IdempotencyError < StandardError; end

    def initialize(cfg)
      @cfg = cfg
    end

    # Raises KillSwitchError if the kill-switch sentinel file exists.
    # Create the file to halt all ordering: `touch data/PAUSE`
    # Remove it to resume:                  `rm data/PAUSE`
    def check_kill_switch!
      kill_file = File.expand_path(@cfg.safety.kill_switch_file, REPO_ROOT)
      return unless File.exist?(kill_file)

      raise KillSwitchError,
            "Kill switch active: #{kill_file} exists. Remove it to resume ordering."
    end

    # Raises SpendingCapError if +total+ exceeds the configured spending cap.
    # total may be nil (unknown) — in that case the cap check is skipped.
    def check_spending_cap!(total)
      return if total.nil?

      cap = @cfg.safety.spending_cap_usd.to_f
      return if total.to_f <= cap

      raise SpendingCapError,
            format('Cart total $%.2f exceeds spending cap $%.2f', total, cap)
    end

    # Returns the idempotency key for a given week_start date.
    # week_start may be a Date or an ISO-8601 String.
    def idempotency_key(week_start)
      iso = week_start.is_a?(String) ? week_start : week_start.iso8601
      "autochef-#{iso}"
    end

    # Raises IdempotencyError if a 'cart_built' OrderHistory row already exists
    # for this run_key. Safe to re-run the same week without double-building.
    def check_idempotency!(run_key)
      existing = Models::OrderHistory
                 .for_run_key(run_key)
                 .where(status: 'cart_built')
                 .first
      return unless existing

      raise IdempotencyError,
            "Cart already built for run_key=#{run_key} " \
            "(order_history id=#{existing.id}). Pass --force to rebuild."
    end

    # Returns a human-readable deviation warning string if +cart_total+ deviates
    # from +est_total+ by more than cart_deviation_alert_pct. Returns nil if the
    # deviation is within tolerance or if either value is nil/zero.
    def deviation_warning(est_total, cart_total)
      return nil if est_total.nil? || cart_total.nil?
      return nil if est_total.to_f.zero?

      pct       = ((cart_total.to_f - est_total.to_f).abs / est_total.to_f * 100).round(1)
      threshold = @cfg.safety.cart_deviation_alert_pct.to_f
      return nil if pct <= threshold

      format(
        'Cart total $%.2f deviates %.1f%% from estimate $%.2f (threshold: %g%%)',
        cart_total, pct, est_total, threshold
      )
    end
  end
end
