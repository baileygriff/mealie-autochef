# frozen_string_literal: true

require "yaml"
require "dotenv"
require "active_model"

module Autochef
  # Loads and validates config.yaml + .env into a single Config object.
  #
  # Usage:
  #   cfg = Autochef::Config.load
  #   cfg.mealie.url
  #   cfg.safety.spending_cap_usd
  #
  # Each nested section is its own ActiveModel-validated class. ActiveModel
  # gives us the same validation ergonomics Rails apps use for forms/models,
  # without needing ActiveRecord or a database — this class never touches
  # the DB. That's the whole point of using ActiveModel here instead of
  # ActiveRecord: validation only, no persistence.
  WEEKDAYS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze
  DAY_TYPES = %w[cook leftover out skip].freeze

  REPO_ROOT = File.expand_path("../..", __dir__)
  DEFAULT_CONFIG_PATH = File.join(REPO_ROOT, "config.yaml")
  DEFAULT_ENV_PATH = File.join(REPO_ROOT, ".env")

  class ConfigError < StandardError; end

  # Base class: validates on init, raises ConfigError with all messages
  # joined (rather than ActiveModel's default of silently returning false
  # from #valid?) so a bad config fails loudly and immediately on load.
  class ValidatedStruct
    include ActiveModel::Validations

    def initialize(attrs = {})
      attrs.each { |k, v| instance_variable_set("@#{k}", v) }
      validate!
    end

    def validate!
      return if valid?

      raise ConfigError, "#{self.class.name}: #{errors.full_messages.join('; ')}"
    end
  end

  class MealieConfig < ValidatedStruct
    attr_reader :url, :eligible_tag, :next_order_list, :api_token

    validates :url, :eligible_tag, :next_order_list, presence: true
  end

  class StoreConfig < ValidatedStruct
    attr_reader :name, :fulfillment

    validates :name, presence: true
    validates :fulfillment, inclusion: { in: %w[pickup] }
    # NOTE: 'pickup' is the only allowed value, on purpose. MEMORY.md lists
    # pickup-vs-delivery as a locked decision — don't relitigate without a
    # documented reason. If that ever changes, widen this `inclusion` list
    # deliberately, in one place.
  end

  class ScheduleConfig < ValidatedStruct
    attr_reader :weekly_run, :pickup_window_pref, :pickup_day

    validates :weekly_run, :pickup_window_pref, presence: true
    validates :pickup_day, inclusion: { in: WEEKDAYS }
  end

  class MealsConfig < ValidatedStruct
    attr_reader :meal_types, :default_servings, :week_layout

    validates :default_servings, numericality: { greater_than: 0, only_integer: true }

    validate :meal_types_present
    validate :week_layout_valid

    private

    def meal_types_present
      errors.add(:meal_types, "must be a non-empty array") if meal_types.nil? || meal_types.empty?
    end

    def week_layout_valid
      return errors.add(:week_layout, "must be a hash") unless week_layout.is_a?(Hash)

      bad_days = week_layout.keys.map(&:to_s) - WEEKDAYS
      errors.add(:week_layout, "has unknown day(s): #{bad_days}") if bad_days.any?

      bad_types = week_layout.values.map(&:to_s) - DAY_TYPES
      errors.add(:week_layout, "has unknown day type(s): #{bad_types}") if bad_types.any?
    end
  end

  class VarietyConfig < ValidatedStruct
    attr_reader :max_same_cuisine_per_week, :max_same_protein_per_week

    validates :max_same_cuisine_per_week, :max_same_protein_per_week,
              numericality: { greater_than_or_equal_to: 0 }
  end

  class ScoringWeights < ValidatedStruct
    attr_reader :rating, :tag_affinity, :recency_penalty, :swap_penalty, :nutrition_fit

    validates :rating, :tag_affinity, :recency_penalty, :swap_penalty, :nutrition_fit,
              numericality: true
  end

  class SelectionConfig < ValidatedStruct
    attr_reader :repeat_avoidance_weeks, :variety, :scoring_weights

    validates :repeat_avoidance_weeks, numericality: { greater_than_or_equal_to: 0 }

    def initialize(attrs = {})
      attrs = attrs.dup
      attrs[:variety] = VarietyConfig.new(attrs[:variety] || {})
      attrs[:scoring_weights] = ScoringWeights.new(attrs[:scoring_weights] || {})
      super(attrs)
    end
  end

  class NutritionConfig < ValidatedStruct
    attr_reader :enabled, :target_protein_per_serving_g

    validates :target_protein_per_serving_g, numericality: { greater_than: 0 }
  end

  class LLMConfig < ValidatedStruct
    attr_reader :provider, :model, :enabled, :freeform_note_default, :api_key

    validates :provider, inclusion: { in: %w[anthropic] }
    validates :model, presence: true
  end

  class NotifyConfig < ValidatedStruct
    attr_reader :channel, :telegram_bot_token, :telegram_chat_id

    validates :channel, inclusion: { in: %w[telegram ntfy] }
  end

  class SafetyConfig < ValidatedStruct
    attr_reader :dry_run, :spending_cap_usd, :cart_deviation_alert_pct, :kill_switch_file

    validates :spending_cap_usd, :cart_deviation_alert_pct, numericality: { greater_than: 0 }
    validates :kill_switch_file, presence: true

    def initialize(attrs = {})
      super
      # Not a hard failure (Phase 7 may legitimately flip this) but dry_run
      # is the single most important flag in the whole system — make any
      # accidental flip-to-live impossible to miss in logs.
      warn "!!! WARNING: safety.dry_run is FALSE. Auto-checkout is LIVE. !!!" if dry_run == false
    end
  end

  class Config
    attr_reader :mealie, :store, :schedule, :meals, :selection,
                :nutrition, :llm, :notify, :safety

    def self.load(config_path: DEFAULT_CONFIG_PATH, env_path: DEFAULT_ENV_PATH)
      unless File.exist?(config_path)
        raise ConfigError,
              "Config file not found: #{config_path}. Create it from README setup steps."
      end

      if File.exist?(env_path)
        Dotenv.load(env_path)
      else
        Dotenv.load # picks up ambient environment / Docker-injected vars
      end

      raw = YAML.safe_load_file(config_path, symbolize_names: true)

      raw[:mealie][:api_token] = ENV.fetch("MEALIE_API_TOKEN", "")
      raw[:llm][:api_key] = ENV.fetch("ANTHROPIC_API_KEY", "")
      raw[:notify][:telegram_bot_token] = ENV.fetch("TELEGRAM_BOT_TOKEN", "")
      raw[:notify][:telegram_chat_id] = ENV.fetch("TELEGRAM_CHAT_ID", "")

      cfg = new(raw)
      cfg.send(:warn_on_missing_secrets)
      cfg
    end

    def initialize(raw)
      @mealie = MealieConfig.new(raw[:mealie])
      @store = StoreConfig.new(raw[:store])
      @schedule = ScheduleConfig.new(raw[:schedule])
      @meals = MealsConfig.new(raw[:meals])
      @selection = SelectionConfig.new(raw[:selection])
      @nutrition = NutritionConfig.new(raw[:nutrition])
      @llm = LLMConfig.new(raw[:llm])
      @notify = NotifyConfig.new(raw[:notify])
      @safety = SafetyConfig.new(raw[:safety])
    end

    private

    def warn_on_missing_secrets
      missing = []
      missing << "MEALIE_API_TOKEN" if mealie.api_token.to_s.empty?
      missing << "ANTHROPIC_API_KEY" if llm.enabled && llm.api_key.to_s.empty?
      if notify.channel == "telegram"
        missing << "TELEGRAM_BOT_TOKEN" if notify.telegram_bot_token.to_s.empty?
        missing << "TELEGRAM_CHAT_ID" if notify.telegram_chat_id.to_s.empty?
      end

      warn "!!! WARNING: missing secrets in .env: #{missing.join(', ')} !!!" if missing.any?
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  # Quick manual check: `ruby lib/autochef/config.rb` (after bundle install)
  cfg = Autochef::Config.load
  require "json"
  puts({
    mealie: cfg.mealie.url,
    store: cfg.store.name,
    fulfillment: cfg.store.fulfillment,
    week_layout: cfg.meals.week_layout
  }.to_json)
end
