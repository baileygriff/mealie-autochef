# frozen_string_literal: true

require 'date'
require_relative 'models/plan_history'

module Autochef
  # Schedules night-before thaw nudges and optional cook-morning pings via
  # rufus-scheduler. Integrated into `main.rb serve` alongside the Telegram bot.
  #
  # Usage (in cmd_serve):
  #   scheduler = Rufus::Scheduler.new
  #   reminders = Autochef::Reminders.new(cfg, notifier: notifier)
  #   reminders.schedule!(scheduler)
  #   notifier.run_bot  # blocking — scheduler keeps running in background threads
  class Reminders
    def initialize(cfg, notifier:)
      @cfg      = cfg
      @notifier = notifier
    end

    # Register cron jobs on the given Rufus::Scheduler instance.
    # Cron fires daily; the job checks whether today/tomorrow is a cook day.
    def schedule!(scheduler)
      h_eve, m_eve = parse_time(@cfg.schedule.thaw_reminder_time)
      scheduler.cron("#{m_eve} #{h_eve} * * *") do
        safe_run { check_and_send_thaw! }
      end

      if @cfg.schedule.morning_ping_enabled?
        h_morn, m_morn = parse_time(@cfg.schedule.morning_ping_time)
        scheduler.cron("#{m_morn} #{h_morn} * * *") do
          safe_run { check_and_send_morning! }
        end
      end

      thaw_label  = @cfg.schedule.thaw_reminder_time
      morn_label  = @cfg.schedule.morning_ping_enabled? ? ", morning ping: #{@cfg.schedule.morning_ping_time}" : ''
      puts "Reminders scheduled (thaw: #{thaw_label}#{morn_label})"
    end

    private

    def check_and_send_thaw!
      tomorrow = Date.today + 1
      entry    = find_plan_entry_for(tomorrow)
      return unless entry

      @notifier.send_thaw_reminder(date: tomorrow, recipe_name: entry['recipe_name'].to_s)
    end

    def check_and_send_morning!
      today = Date.today
      entry = find_plan_entry_for(today)
      return unless entry

      @notifier.send_morning_ping(date: today, recipe_name: entry['recipe_name'].to_s)
    end

    # Returns the plan entry hash for the given date from the most recent
    # approved plan, or nil if there is no cook-day assignment for that date.
    def find_plan_entry_for(date)
      history = Models::PlanHistory.where(approved: 1).order(created_at: :desc).first
      return nil unless history

      history.plan[date.iso8601]
    end

    # Parse "HH:MM" → [hour_int, minute_int]. Defaults to [18, 0] on bad input.
    def parse_time(time_str)
      parts = time_str.to_s.split(':').map(&:to_i)
      [parts[0] || 18, parts[1] || 0]
    end

    def safe_run
      yield
    rescue StandardError => e
      warn "Reminder job error: #{e.class}: #{e.message}"
    end
  end
end
