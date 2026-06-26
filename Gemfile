source "https://rubygems.org"

ruby ">= 3.2"

# ORM — used standalone (ActiveRecord::Base.establish_connection), no Rails app.
gem "activerecord", "~> 7.1"
gem "activemodel", "~> 7.1"
gem "sqlite3", "~> 1.7"

# Config / env
gem "dotenv", "~> 3.1"

# HTTP (Mealie API, Anthropic API, Uptime Kuma ping)
gem "httparty", "~> 0.21"

# Telegram bot (Phase 3)
gem "telegram-bot-ruby", "~> 0.23"

# Scheduling (in-container cron alternative; Phase 6+, listed now per spec)
gem "rufus-scheduler", "~> 3.9"

# YAML config — yaml is stdlib in modern Ruby, no gem needed; left as a comment
# for visibility: `require "yaml"` is built in.

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.65", require: false
end
