# frozen_string_literal: true

module Autochef
  class Error < StandardError; end

  class ConfigError   < Error; end
  class LlmError      < Error; end
  class MealieError   < Error; end
  class PlanError     < Error; end
  class ShopError     < Error; end
  class FeedbackError < Error; end

  class CartError < Error; end

  class SessionExpiredError < CartError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("Cart session expired: #{reason}")
    end
  end

  class SpendingCapError < CartError
    attr_reader :total, :cap

    def initialize(total:, cap:)
      @total = total
      @cap   = cap
      super("Cart total $#{total} exceeds cap $#{cap}")
    end
  end
end
