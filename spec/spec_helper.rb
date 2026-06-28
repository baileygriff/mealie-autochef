# frozen_string_literal: true

require 'active_record'
require 'active_model'
require 'sqlite3'
require 'fileutils'
require 'date'

# Point ActiveRecord at an in-memory SQLite database for all tests.
# This means specs never touch data/autochef.db and each run starts clean.
ActiveRecord::Base.establish_connection(
  adapter:  'sqlite3',
  database: ':memory:'
)

# Run all migrations against the in-memory DB before any example runs.
MIGRATIONS_PATH = File.expand_path('../db/migrate', __dir__)

ActiveRecord::Base.connection_pool.tap do |pool|
  ActiveRecord::MigrationContext.new(
    [MIGRATIONS_PATH],
    pool.schema_migration,
    pool.internal_metadata
  ).migrate
end

# Suppress migration output in test runs.
ActiveRecord::Migration.verbose = false

# Load models (they just need an AR connection to be usable).
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'autochef/models/recipe_stat'
require 'autochef/models/tag_weight'
require 'autochef/models/plan_history'
require 'autochef/models/order_history'
require 'autochef/models/recurring_item'
require 'autochef/models/product_map'
require 'autochef/models/manual_addition'
require 'autochef/models/week_pref'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # Wrap each example in a transaction and roll back after, so DB is clean
  # between tests without needing to truncate tables.
  config.around(:each) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random
  Kernel.srand config.seed
end
