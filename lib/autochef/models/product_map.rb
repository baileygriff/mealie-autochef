# frozen_string_literal: true

module Autochef
  module Models
    # Bridges a Mealie food/ingredient to a purchasable Food Lion product
    # (search term or known product id, pack size, default quantity).
    # Seeded interactively via scripts/seed_product_map.rb (Phase 4).
    # Unmapped ingredients are flagged at cart-build time, never guessed.
    class ProductMap < ActiveRecord::Base
      self.table_name = "product_map"
      self.primary_key = "key"

      validates :rounding, inclusion: { in: %w[up down nearest] }, allow_nil: true
    end
  end
end
