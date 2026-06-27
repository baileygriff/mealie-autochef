# frozen_string_literal: true

require 'active_record'

module Autochef
  # Establishes the ActiveRecord connection for autochef.db, standalone
  # (no Rails app). This is the one line that makes ActiveRecord usable
  # outside Rails: establish_connection works fine on its own, models just
  # need ActiveRecord::Base as their superclass (see lib/autochef/models/).
  module Database
    DEFAULT_DB_PATH = File.expand_path('../../data/autochef.db', __dir__)

    def self.connect!(db_path = DEFAULT_DB_PATH)
      FileUtils.mkdir_p(File.dirname(db_path))
      ActiveRecord::Base.establish_connection(
        adapter: 'sqlite3',
        database: db_path
      )
    end

    # Runs all pending migrations in db/migrate against the current connection.
    # Equivalent to `rails db:migrate`, called directly since there's no Rails
    # app to provide the rake task.
    def self.migrate!(migrations_path = File.expand_path('../../db/migrate', __dir__))
      pool = ActiveRecord::Base.connection_pool
      ActiveRecord::MigrationContext.new(
        [migrations_path],
        pool.schema_migration,
        pool.internal_metadata
      ).migrate
    end
  end
end
