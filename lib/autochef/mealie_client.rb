# frozen_string_literal: true

require 'httparty'
require 'json'

module Autochef
  # Thin HTTP wrapper over the Mealie REST API.
  #
  # All list methods return flat arrays — pagination is handled transparently.
  # All methods return plain Ruby hashes (parsed JSON). No AR models here;
  # that layer lives in lib/autochef/models/.
  #
  # Usage:
  #   client = Autochef::MealieClient.new(base_url: cfg.mealie.url,
  #                                        api_token: cfg.mealie.api_token)
  #   pool = client.eligible_pool("auto-plan")
  #
  # Errors raised:
  #   MealieClient::AuthError  — 401 (bad/missing token)
  #   MealieClient::NotFound   — 404
  #   MealieClient::Error      — any other API failure
  class MealieClient
    class Error < StandardError; end
    class AuthError < Error; end
    class NotFound < Error; end

    # Default shelf-life estimates (days) matched against food names.
    # First match wins. Used by scripts/tag_recipes.rb to suggest values.
    SHELF_LIFE_DEFAULTS = [
      [/\b(salmon|tuna|shrimp|prawn|scallop|cod|tilapia|halibut|fish|seafood)\b/i, 2],
      [/\b(ground\s*(beef|pork|turkey|chicken|lamb)|mince)\b/i, 2],
      [/\b(chicken|turkey)\b/i, 3],
      [/\b(beef|pork|lamb|veal|steak|brisket|roast)\b/i, 3],
      [/\b(herb|parsley|cilantro|basil|dill|chive|mint|tarragon|thyme|rosemary)\b/i, 3],
      [/\b(milk|cream|yogurt|sour\s*cream|half.and.half|heavy\s*cream|buttermilk)\b/i, 7],
      [/\b(cheese|butter|margarine)\b/i, 14],
      [/\b(lettuce|spinach|arugula|mixed\s*greens|salad|cucumber|zucchini|asparagus|broccoli|kale)\b/i, 5],
      [/\b(tomato|bell\s*pepper|mushroom|corn|snap\s*pea|green\s*bean)\b/i, 7],
      [/\b(carrot|celery|cabbage|cauliflower|brussel|beet|turnip|parsnip)\b/i, 10],
      [/\b(potato|sweet\s*potato|yam)\b/i, 14],
      [/\b(onion|shallot|leek|scallion|green\s*onion)\b/i, 21],
      [/\b(garlic|ginger)\b/i, 21],
      [/\b(apple|pear|orange|lemon|lime|grape|berry|berries|mango|pineapple)\b/i,  7],
      [/\b(banana|avocado|peach|plum|nectarine)\b/i,                               5],
      [/\b(egg)\b/i, 21],
      [/\b(tofu|tempeh|seitan)\b/i,                                                5],
      [/\b(bacon|sausage|hot\s*dog|deli|lunch\s*meat)\b/i,                         7]
    ].freeze

    # Fallback when no pattern matches — assume pantry-stable.
    PANTRY_DEFAULT_DAYS = 365

    def initialize(base_url:, api_token:)
      @base_url  = base_url.chomp('/')
      @api_token = api_token
    end

    # GET /api/app/about — public endpoint, no auth required.
    # Returns hash with "version", "productionMode", etc.
    def ping
      get('/api/app/about')
    end

    # GET /api/recipes — returns all recipes (paginates automatically).
    # Results are plain summary hashes; they include tags, rating, lastMade.
    def recipes
      paginate('/api/recipes')
    end

    # GET /api/recipes/{slug_or_id} — full recipe detail including ingredients.
    def recipe(slug_or_id)
      get("/api/recipes/#{slug_or_id}")
    end

    # Returns the subset of recipes tagged with eligible_tag (client-side filter).
    def eligible_pool(eligible_tag)
      recipes.select { |r| tag?(r, eligible_tag) }
    end

    # Add tags to a recipe by name (non-destructive: merges with existing tags).
    # tag_names — array of strings, e.g. ["auto-plan", "cuisine:american"]
    # Fetches the current recipe first to avoid clobbering existing tags.
    def add_recipe_tags(slug, tag_names)
      r = recipe(slug)
      existing      = r['tags'] || []
      existing_names = existing.map { |t| t['name'] }
      new_tags      = tag_names.reject { |n| existing_names.include?(n) }
                               .map    { |n| ensure_tag(n) }
      patch("/api/recipes/#{slug}", { 'tags' => existing + new_tags })
    end

    # Replace ALL tags on a recipe (use when you want a clean set).
    def set_recipe_tags(slug, tag_names)
      tags = tag_names.map { |n| ensure_tag(n) }
      patch("/api/recipes/#{slug}", { 'tags' => tags })
    end

    # Create a tag by name if it doesn't exist; return the full tag object
    # (with slug + id) either way. Mealie v3 requires slug on recipe PATCH.
    def ensure_tag(name)
      result = post('/api/organizers/tags', { 'name' => name })
      return result if result['slug']
      # Already exists — find it
      paginate('/api/organizers/tags').find { |t| t['name'].casecmp?(name) } ||
        raise("Could not create or find tag: #{name}")
    end

    # GET /api/foods — returns all foods (paginates automatically).
    def foods
      paginate('/api/foods')
    end

    # GET /api/foods/{id} — single food detail (includes extras, onHand).
    def food(food_id)
      get("/api/foods/#{food_id}")
    end

    # PATCH /api/foods/{id} extras — merges new_extras into existing extras.
    # Safe: fetches current extras first so unrelated keys are preserved.
    def update_food_extras(food_id, new_extras)
      current       = food(food_id)
      merged_extras = (current['extras'] || {}).merge(new_extras.transform_keys(&:to_s))
      patch("/api/foods/#{food_id}", { 'extras' => merged_extras })
    end

    # GET /api/groups/shopping/lists — all shopping lists for the group.
    def shopping_lists
      paginate('/api/groups/shopping/lists')
    end

    # Find a shopping list by name, or create it if it doesn't exist.
    # Returns the list hash (id, name, etc.).
    def find_or_create_shopping_list(name)
      lists = shopping_lists
      existing = lists.find { |l| l['name'].to_s.casecmp?(name) }
      return existing if existing

      post('/api/groups/shopping/lists', { 'name' => name })
    end

    # POST /api/groups/shopping/lists/{list_id}/items — add one item to a list.
    # quantity, unit, note are optional.
    def add_shopping_list_item(list_id, name:, quantity: 1, unit: nil, note: nil)
      body = { 'shoppingListId' => list_id, 'note' => name, 'quantity' => quantity.to_f }
      body['unit'] = { 'name' => unit } if unit
      body['extras'] = { 'source' => note } if note
      post("/api/groups/shopping/lists/#{list_id}/items", body)
    end

    # Like add_shopping_list_item but marks the item with autochef_managed: true
    # so clear_autochef_items can identify and remove it on re-push.
    # food_id and label are optional Mealie food/label linkage.
    def add_autochef_item(list_id, name:, quantity: 1, unit: nil, food_id: nil, label: nil, note: nil)
      body = {
        'shoppingListId' => list_id,
        'note'           => name,
        'quantity'       => quantity.to_f,
        'extras'         => { 'autochef_managed' => 'true' }
      }
      body['unit']    = { 'name' => unit }    if unit
      body['food']    = { 'id'   => food_id } if food_id
      body['label']   = { 'name' => label }   if label
      body['extras']['source_note'] = note     if note
      post("/api/groups/shopping/lists/#{list_id}/items", body)
    end

    # Delete all items in a list that were created by autochef (extras.autochef_managed == 'true').
    # Preserves manual adds and items entered through Mealie's own UI.
    # Returns the count of deleted items.
    def clear_autochef_items(list_id)
      list  = shopping_list(list_id)
      items = list['listItems'] || list['items'] || []

      autochef_items = items.select do |item|
        (item['extras'] || {})['autochef_managed'].to_s == 'true'
      end

      autochef_items.each { |item| remove_shopping_list_item(list_id, item['id']) }
      autochef_items.size
    end

    # DELETE /api/groups/shopping/lists/{list_id}/items/{item_id}
    def remove_shopping_list_item(list_id, item_id)
      resp = HTTParty.delete(
        "#{@base_url}/api/groups/shopping/lists/#{list_id}/items/#{item_id}",
        headers: auth_headers,
        timeout: 30
      )
      handle_response!(resp)
    end

    # GET /api/groups/shopping/lists/{list_id} — full list with items.
    def shopping_list(list_id)
      get("/api/groups/shopping/lists/#{list_id}")
    end

    # POST /api/admin/backups — trigger Mealie's built-in backup.
    # Requires an admin token. Returns the response hash.
    def trigger_backup
      post('/api/admin/backups', {})
    end

    # Suggest a shelf_life_days value for a food by name.
    # Returns an Integer, or PANTRY_DEFAULT_DAYS if no pattern matches.
    def self.suggest_shelf_life(food_name)
      SHELF_LIFE_DEFAULTS.each do |pattern, days|
        return days if food_name.to_s.match?(pattern)
      end
      PANTRY_DEFAULT_DAYS
    end

    private

    def get(path, params = {})
      resp = HTTParty.get(
        "#{@base_url}#{path}",
        query: params.empty? ? nil : params,
        headers: auth_headers,
        timeout: 30
      )
      handle_response!(resp)
    end

    def patch(path, body)
      resp = HTTParty.patch(
        "#{@base_url}#{path}",
        body: body.to_json,
        headers: auth_headers,
        timeout: 30
      )
      handle_response!(resp)
    end

    def post(path, body)
      resp = HTTParty.post(
        "#{@base_url}#{path}",
        body: body.to_json,
        headers: auth_headers,
        timeout: 30
      )
      handle_response!(resp)
    end

    def auth_headers
      {
        'Authorization' => "Bearer #{@api_token}",
        'Content-Type' => 'application/json',
        'Accept' => 'application/json'
      }
    end

    # Fetches all pages of a paginated endpoint and returns a flat array.
    # Mealie paginates via page/perPage query params; response is:
    #   { "page": 1, "total_pages": 3, "items": [...] }
    # (Mealie may use camelCase or snake_case for pagination keys.)
    def paginate(path, params = {})
      all_items = []
      page      = 1

      loop do
        result = get(path, params.merge('page' => page, 'perPage' => 100))

        # If the endpoint returns an array directly (no pagination envelope), done.
        return Array(result) unless result.is_a?(Hash) && result.key?('items')

        all_items.concat(result['items'])

        total_pages = result['total_pages'] || result['totalPages'] || 1
        break if page >= total_pages.to_i

        page += 1
      end

      all_items
    end

    def tag?(recipe, tag_name)
      (recipe['tags'] || []).any? { |t| t['name'].to_s.casecmp?(tag_name) }
    end

    def handle_response!(resp)
      case resp.code
      when 200..299
        resp.parsed_response
      when 401
        raise AuthError, 'Mealie API: 401 unauthorized — check MEALIE_API_TOKEN'
      when 404
        raise NotFound, "Mealie API: 404 not found — #{resp.request&.uri}"
      else
        snippet = resp.body.to_s.slice(0, 300)
        raise Error, "Mealie API: HTTP #{resp.code} — #{snippet}"
      end
    end
  end
end
