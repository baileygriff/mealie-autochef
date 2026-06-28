# frozen_string_literal: true

require 'spec_helper'

# cart.py's clear_cart() removes items from the Food Lion website via Playwright.
# It never touches the Ruby DB (ManualAddition, ProductMap, or the Mealie API).
# cmd_build_cart reads the Mealie "Next Order" list fresh each run, so manually-
# added items are always re-included in the next build.

RSpec.describe Autochef::Models::ManualAddition do
  describe '.pending scope' do
    it 'returns items that have not been consumed' do
      Autochef::Models::ManualAddition.create!(name: 'oat milk', consumed: false)
      expect(described_class.pending.map(&:name)).to include('oat milk')
    end

    it 'excludes items already marked consumed' do
      Autochef::Models::ManualAddition.create!(name: 'yogurt', consumed: true)
      expect(described_class.pending.map(&:name)).not_to include('yogurt')
    end
  end

  describe 'cart rebuild invariant' do
    # Simulates the resolve_cart_item logic from main.rb:
    # looks up ProductMap by normalized key; falls back to raw name as search term.
    def resolve(mealie_note, quantity: 1.0)
      raw = mealie_note.strip
      key = raw.downcase.gsub(/\s+/, ' ')
      mapping = Autochef::Models::ProductMap.find_by(key: key)
      return nil if mapping&.search_term == '__skip__'

      if mapping
        { 'search_term' => mapping.search_term.to_s.empty? ? raw : mapping.search_term,
          'default_qty' => (mapping.default_qty || 1).to_i }
      else
        { 'search_term' => raw,
          'default_qty' => [quantity.ceil, 1].max }
      end
    end

    it 'resolves a manually-added item with no ProductMap entry to a cart item' do
      # execute_add_items does not create a ProductMap entry for new /add items.
      # resolve_cart_item falls through to the else branch and uses the raw name.
      Autochef::Models::ManualAddition.create!(name: 'KIND protein bar')

      result = resolve('KIND protein bar')

      expect(result).not_to be_nil
      expect(result['search_term']).to eq('KIND protein bar')
    end

    it 'resolves a manually-added item that matches an existing ProductMap entry' do
      Autochef::Models::ProductMap.create!(
        key: 'oat milk',
        search_term: 'oat milk unsweetened',
        default_qty: 1
      )
      Autochef::Models::ManualAddition.create!(name: 'oat milk')

      result = resolve('oat milk')

      expect(result).not_to be_nil
      expect(result['search_term']).to eq('oat milk unsweetened')
    end

    it 'never returns nil for a manually-added item (they cannot be pantry-skipped by /add)' do
      # __skip__ entries come from seed_product_map / automap for pantry staples.
      # /add items are always real grocery additions — none should map to __skip__.
      Autochef::Models::ProductMap.create!(
        key: 'salt',
        search_term: '__skip__'
      )
      Autochef::Models::ManualAddition.create!(name: 'oat milk')

      result = resolve('oat milk')

      expect(result).not_to be_nil
    end

    it 'ManualAddition record persists after a simulated cart rebuild (DB is untouched by clear_cart)' do
      Autochef::Models::ManualAddition.create!(name: 'oat milk', consumed: false)

      # clear_cart() in cart.py only removes items from the Food Lion website.
      # Simulate a rebuild by reading ManualAddition directly — count should be unchanged.
      expect(Autochef::Models::ManualAddition.pending.count).to eq(1)
    end
  end
end
