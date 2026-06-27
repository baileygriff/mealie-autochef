# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'autochef/config'

RSpec.describe Autochef::Config do
  let(:valid_yaml) do
    <<~YAML
      mealie:
        url: "http://mealie:9000"
        eligible_tag: "auto-plan"
        next_order_list: "Next Order"

      store:
        name: "Food Lion - Test"
        fulfillment: "pickup"

      schedule:
        weekly_run: "Thu 18:00"
        pickup_window_pref: "Sun 10:00-12:00"
        pickup_day: "Sun"
        thaw_reminder_time: "18:00"
        morning_ping_time: "08:00"
        morning_ping_enabled: false

      meals:
        meal_types: ["dinner"]
        default_servings: 2
        week_layout:
          Sun: cook
          Mon: leftover
          Tue: cook
          Wed: cook
          Thu: leftover
          Fri: out
          Sat: cook

      selection:
        repeat_avoidance_weeks: 3
        variety:
          max_same_cuisine_per_week: 2
          max_same_protein_per_week: 2
        scoring_weights:
          rating: 1.0
          tag_affinity: 0.5
          recency_penalty: 1.0
          swap_penalty: 0.75
          nutrition_fit: 0.5

      nutrition:
        enabled: true
        target_protein_per_serving_g: 45

      llm:
        provider: "anthropic"
        model: "claude-haiku-4-5-20251001"
        enabled: false
        freeform_note_default: ""

      notify:
        channel: "telegram"

      safety:
        dry_run: true
        spending_cap_usd: 150
        cart_deviation_alert_pct: 20
        kill_switch_file: "data/PAUSE"
    YAML
  end

  def write_config(yaml_str)
    dir  = Dir.mktmpdir
    path = File.join(dir, 'config.yaml')
    File.write(path, yaml_str)
    [path, dir]
  end

  around(:each) do |example|
    # Stub env secrets to avoid missing-secret warnings and dotenv side effects.
    ClimateControl = Module.new unless defined?(ClimateControl)
    saved = {
      'MEALIE_API_TOKEN'   => ENV['MEALIE_API_TOKEN'],
      'ANTHROPIC_API_KEY'  => ENV['ANTHROPIC_API_KEY'],
      'TELEGRAM_BOT_TOKEN' => ENV['TELEGRAM_BOT_TOKEN'],
      'TELEGRAM_CHAT_ID'   => ENV['TELEGRAM_CHAT_ID']
    }
    ENV['MEALIE_API_TOKEN']   = 'test-token'
    ENV['ANTHROPIC_API_KEY']  = 'sk-test'
    ENV['TELEGRAM_BOT_TOKEN'] = 'bot-test'
    ENV['TELEGRAM_CHAT_ID']   = '12345'

    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe '.load' do
    it 'loads a valid config without raising' do
      path, dir = write_config(valid_yaml)
      cfg = nil
      expect { cfg = Autochef::Config.load(config_path: path, env_path: '/nonexistent/.env') }
        .not_to raise_error
      FileUtils.rm_rf(dir)

      expect(cfg.mealie.url).to eq('http://mealie:9000')
      expect(cfg.store.name).to eq('Food Lion - Test')
      expect(cfg.store.fulfillment).to eq('pickup')
      # week_layout keys are symbols because config.rb uses symbolize_names: true
      expect(cfg.meals.week_layout[:Sun]).to eq('cook')
      expect(cfg.safety.dry_run).to eq(true)
      expect(cfg.safety.spending_cap_usd).to eq(150)
      expect(cfg.schedule.morning_ping_enabled?).to eq(false)
    end

    it 'raises ConfigError when a required key is missing (empty url)' do
      # Replace url value with empty string — presence: true catches it
      bad_yaml = valid_yaml.gsub('url: "http://mealie:9000"', 'url: ""')
      path, dir = write_config(bad_yaml)
      expect { Autochef::Config.load(config_path: path, env_path: '/nonexistent/.env') }
        .to raise_error(Autochef::ConfigError)
      FileUtils.rm_rf(dir)
    end

    it 'raises ConfigError for an invalid fulfillment value' do
      bad_yaml = valid_yaml.gsub('fulfillment: "pickup"', 'fulfillment: "delivery"')
      path, dir = write_config(bad_yaml)
      expect { Autochef::Config.load(config_path: path, env_path: '/nonexistent/.env') }
        .to raise_error(Autochef::ConfigError, /fulfillment/i)
      FileUtils.rm_rf(dir)
    end

    it 'raises ConfigError for an invalid week_layout day type' do
      bad_yaml = valid_yaml.gsub('Sun: cook', 'Sun: feast')
      path, dir = write_config(bad_yaml)
      expect { Autochef::Config.load(config_path: path, env_path: '/nonexistent/.env') }
        .to raise_error(Autochef::ConfigError, /week layout/i)
      FileUtils.rm_rf(dir)
    end

    it 'overrides mealie.url from MEALIE_URL env var' do
      ENV['MEALIE_URL'] = 'http://localhost:9000'
      path, dir = write_config(valid_yaml)
      cfg = Autochef::Config.load(config_path: path, env_path: '/nonexistent/.env')
      FileUtils.rm_rf(dir)
      expect(cfg.mealie.url).to eq('http://localhost:9000')
    ensure
      ENV.delete('MEALIE_URL')
    end
  end
end
