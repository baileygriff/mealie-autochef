# frozen_string_literal: true

require_relative 'week_prefs_source'
require_relative 'models/week_pref'

module Autochef
  class SinatraPrefsSource
    include WeekPrefsSource

    def fetch(week_start)
      row = Models::WeekPref.find_by(week_start: week_start)
      return nil unless row

      raw = row.prefs
      days = (raw[:days] || {}).each_with_object({}) do |(k, d), h|
        h[k.to_s] = DayPrefs.new(
          meal_type: d[:meal_type],
          dinner:    slot_from(d[:dinner]),
          lunch:     slot_from(d[:lunch])
        )
      end

      WeekPrefs.new(
        week_start:       week_start,
        protein_excludes: raw[:protein_excludes] || [],
        freeform_note:    raw[:freeform_note].to_s,
        days:             days
      )
    end

    def save(week_start, params)
      row = Models::WeekPref.find_or_initialize_by(week_start: week_start)
      row.prefs = build_prefs_hash(params)
      row.save!
    end

    private

    def slot_from(h)
      return MealSlotPrefs.new(enabled: false) unless h
      MealSlotPrefs.new(
        enabled:  h[:enabled] != false,
        servings: h[:servings]&.to_i,
        vibe:     h[:vibe],
        note:     h[:note].to_s
      )
    end

    def build_prefs_hash(params)
      {
        protein_excludes: Array(params[:protein_excludes]),
        freeform_note:    params[:freeform_note].to_s.strip,
        days:             build_days_hash(params)
      }
    end

    def build_days_hash(params)
      (params[:days] || {}).each_with_object({}) do |(date_str, day), h|
        h[date_str] = {
          meal_type: day[:meal_type],
          dinner: {
            enabled:  true,
            servings: day.dig(:dinner, :servings)&.to_i,
            vibe:     day.dig(:dinner, :vibe),
            note:     day.dig(:dinner, :note).to_s.strip
          },
          lunch: {
            enabled:  day.dig(:lunch, :enabled) == '1',
            servings: day.dig(:lunch, :servings)&.to_i,
            vibe:     day.dig(:lunch, :vibe),
            note:     day.dig(:lunch, :note).to_s.strip
          }
        }
      end
    end
  end
end
