#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI + scheduler entrypoint for Mealie AutoChef.
#
# Phase 0 scope: prove the process boots, config loads, the DB migrates,
# Mealie is reachable, and the Uptime Kuma healthcheck fires. Real planning
# / cart-building commands (`plan`, `build-cart`, `sync`, `backup`) land in
# later phases.
#
# Usage:
#   bundle exec ruby main.rb check   # Phase 0 sanity check
#   bundle exec ruby main.rb serve   # long-running mode (placeholder until rufus-scheduler wiring lands)

require "httparty"
require_relative "lib/autochef/config"
require_relative "lib/autochef/database"

def ping_uptime_kuma(push_url)
  if push_url.to_s.empty?
    puts "Uptime Kuma push URL not configured (UPTIME_KUMA_PUSH_URL) — skipping ping."
    return false
  end

  resp = HTTParty.get(push_url, timeout: 10)
  if resp.success?
    puts "Uptime Kuma ping OK (#{resp.code})"
    true
  else
    puts "Uptime Kuma ping FAILED: HTTP #{resp.code}"
    false
  end
rescue StandardError => e
  # Never let a healthcheck failure crash the run it's reporting on.
  puts "Uptime Kuma ping FAILED: #{e.message}"
  false
end

def check_mealie_connection(base_url, _api_token)
  # Hits Mealie's /api/app/about (no auth required) to confirm reachability.
  # Authenticated calls (recipes, shopping lists) start in Phase 1
  # (mealie_client.rb).
  url = "#{base_url.chomp('/')}/api/app/about"
  resp = HTTParty.get(url, timeout: 10)
  if resp.success?
    puts "Mealie reachable at #{base_url} — version #{resp.parsed_response['version'] || '?'}"
    true
  else
    puts "Mealie connection FAILED at #{url}: HTTP #{resp.code}"
    false
  end
rescue StandardError => e
  puts "Mealie connection FAILED at #{url}: #{e.message}"
  false
end

def cmd_check
  puts "=== Mealie AutoChef — Phase 0 sanity check ==="

  begin
    cfg = Autochef::Config.load
  rescue StandardError => e
    puts "Config load FAILED: #{e.message}"
    return 1
  end
  puts "Config loaded and validated OK."

  begin
    Autochef::Database.connect!
    Autochef::Database.migrate!
  rescue StandardError => e
    puts "DB init/migrate FAILED: #{e.message}"
    return 1
  end
  puts "Database initialized and migrated OK."

  mealie_ok = check_mealie_connection(cfg.mealie.url, cfg.mealie.api_token)
  ping_uptime_kuma(ENV.fetch("UPTIME_KUMA_PUSH_URL", ""))

  if mealie_ok
    puts "\nResult: OK"
    0
  else
    puts "\nResult: PARTIAL — config/db OK, Mealie unreachable (expected if Mealie"
    puts "isn't on mealie_net yet, or this isn't running inside Docker)."
    1
  end
end

def not_implemented_yet(command)
  puts "`#{command}` is not implemented yet — it lands in a later build phase. " \
       "See MEALIE_AUTOMATION_PLAN.md section 10 for the phase breakdown."
  1
end

def main
  command = ARGV[0]

  case command
  when "check", "serve"
    # `serve` is just `check` for now — the real scheduler (rufus-scheduler)
    # is wired up once `plan` and `build-cart` exist to schedule.
    cmd_check
  when "plan", "build-cart", "sync", "backup"
    not_implemented_yet(command)
  when nil
    puts "Usage: ruby main.rb <check|serve|plan|build-cart|sync|backup>"
    1
  else
    puts "Unknown command: #{command}"
    1
  end
end

exit(main) if __FILE__ == $PROGRAM_NAME
