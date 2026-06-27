# frozen_string_literal: true

require 'date'
require_relative 'models/plan_history'
require_relative 'models/product_map'
require_relative 'models/manual_addition'
require_relative 'recurring'

module Autochef
  # Builds the consolidated "Next Order" shopping list from an approved plan.
  #
  # Flow:
  #   1. Scale recipe ingredients by planned servings / recipe base servings.
  #   2. Exclude On-Hand (pantry) foods.
  #   3. Deduplicate: sum quantities for the same food + unit.
  #   4. Apply product_map: resolve each ingredient to a purchasable item.
  #      Unmapped ingredients are collected for flagging — never silently guessed.
  #   5. Inject due recurring staples.
  #   6. Clear autochef-managed items from Mealie "Next Order" (preserves manual adds).
  #   7. Push recipe ingredients + staples to Mealie, tagged autochef_managed.
  #   8. Mark pending manual_additions as consumed and update recurring last_added.
  #
  # Returns a ShoppingResult with counts and the unmapped-item list for surfacing
  # to Bailey via Telegram.
  class ShoppingListBuilder
    ShoppingResult = Struct.new(
      :pushed_count,        # Integer — total items pushed to Mealie
      :recipe_items,        # Integer — ingredient items from the plan
      :recurring_count,     # Integer — recurring staples added this run
      :manual_count,        # Integer — pending manual additions consumed
      :unmapped_items,      # Array<String> — ingredient names with no product_map entry
      :warnings,            # Array<String> — non-blocking issues
      keyword_init: true
    )

    def initialize(cfg, mealie_client:)
      @cfg    = cfg
      @mealie = mealie_client
    end

    # Main entry point. plan_history is a Models::PlanHistory record.
    # Returns ShoppingResult.
    def build_and_push(plan_history)
      warnings      = []
      unmapped      = []

      # 1–4: collect + deduplicate + product map
      ingredients = collect_ingredients(plan_history, warnings)
      deduped     = deduplicate(ingredients, warnings)
      mapped, unmapped_items = apply_product_map(deduped)

      # 5: recurring items due today
      injector      = RecurringInjector.new(@cfg)
      due_staples   = injector.due_items(as_of_date: Date.today)

      # 6: clear autochef-managed items from Next Order, preserve manual adds
      list = @mealie.find_or_create_shopping_list(@cfg.mealie.next_order_list)
      list_id = list['id']
      cleared = @mealie.clear_autochef_items(list_id)
      warnings << "Cleared #{cleared} stale autochef item(s) from Next Order." if cleared.positive?

      # 7a: push recipe ingredients
      recipe_items_pushed = 0
      mapped.each do |item|
        push_ingredient(list_id, item)
        recipe_items_pushed += 1
      end

      # 7b: push due recurring staples
      due_staples.each do |staple|
        @mealie.add_autochef_item(
          list_id,
          name:     staple.name,
          quantity: staple.quantity.to_f,
          unit:     staple.unit
        )
      end

      # 8: mark recurring as added + manual additions as consumed
      injector.mark_added!(due_staples)
      manual_pending = Models::ManualAddition.pending.to_a
      Models::ManualAddition.where(id: manual_pending.map(&:id)).update_all(consumed: true)

      ShoppingResult.new(
        pushed_count:    recipe_items_pushed + due_staples.size,
        recipe_items:    recipe_items_pushed,
        recurring_count: due_staples.size,
        manual_count:    manual_pending.size,
        unmapped_items:  unmapped_items,
        warnings:        warnings
      )
    end

    private

    # Returns array of IngredientRow hashes: {food_name, food_id, quantity, unit, label, source_recipe}
    def collect_ingredients(plan_history, warnings)
      items = []

      plan_history.plan.each do |date_str, entry|
        recipe_id   = entry['recipe_id']
        servings    = entry['servings'].to_f
        recipe_name = entry['recipe_name'].to_s

        full = @mealie.recipe(recipe_id)
        base_servings = parse_yield(full['recipeYield'])
        scale = servings / base_servings.to_f

        (full['recipeIngredient'] || []).each do |ing|
          food = ing['food']

          # Skip on-hand (pantry) items — Mealie already excludes them from lists.
          next if food && food['onHand']

          qty       = (ing['quantity'] || 1).to_f * scale
          unit_name = ing.dig('unit', 'name')
          food_id   = food&.fetch('id', nil)
          food_name = food&.fetch('name', nil) || ing['note'].to_s.strip
          label     = food&.dig('label', 'name')

          next if food_name.empty?

          items << {
            food_name:     food_name,
            food_id:       food_id,
            quantity:      qty,
            unit:          unit_name,
            label:         label,
            source_recipe: recipe_name
          }
        end
      rescue StandardError => e
        warnings << "Could not fetch recipe #{recipe_id} (#{recipe_name}): #{e.message}"
      end

      items
    end

    # Merge rows with the same normalized food name + unit. If units differ for
    # the same food, keep them as separate rows (can't safely convert units).
    def deduplicate(items, _warnings)
      grouped = items.group_by { |i| [normalize(i[:food_name]), i[:unit].to_s.downcase] }

      grouped.map do |(_name_key, _unit_key), rows|
        base = rows.first.dup
        base[:quantity] = rows.sum { |r| r[:quantity] }
        # Collect all source recipes for provenance in the push note.
        base[:source_recipe] = rows.map { |r| r[:source_recipe] }.uniq.join(', ')
        base
      end
    end

    # For each deduplicated item, look up the product_map.
    # Returns [all_items_with_map_info, unmapped_names].
    # Items without a map entry are still returned — they're pushed as-is and flagged.
    def apply_product_map(items)
      unmapped_names = []

      annotated = items.map do |item|
        key     = normalize(item[:food_name])
        mapping = Models::ProductMap.find_by(key: key)

        if mapping
          item.merge(product_map: mapping)
        else
          unmapped_names << item[:food_name]
          item.merge(product_map: nil)
        end
      end

      [annotated, unmapped_names]
    end

    # Push one ingredient item to Mealie. Uses product_map display name if available.
    def push_ingredient(list_id, item)
      mapping      = item[:product_map]
      display_name = mapping&.display_name.to_s.strip
      display_name = item[:food_name] if display_name.empty?

      @mealie.add_autochef_item(
        list_id,
        name:     display_name,
        quantity: item[:quantity].round(2),
        unit:     item[:unit],
        food_id:  item[:food_id],
        label:    item[:label],
        note:     "from: #{item[:source_recipe]}"
      )
    end

    # Parse servings from Mealie's recipeYield field, which can be nil, an int,
    # or a string like "4 servings". Falls back to config default_servings.
    def parse_yield(recipe_yield)
      return @cfg.meals.default_servings if recipe_yield.nil?

      parsed = recipe_yield.to_s.scan(/\d+/).first&.to_i
      (parsed && parsed.positive?) ? parsed : @cfg.meals.default_servings
    end

    def normalize(name)
      name.to_s.downcase.strip.gsub(/\s+/, ' ')
    end
  end
end
