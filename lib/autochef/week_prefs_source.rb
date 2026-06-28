# frozen_string_literal: true

module Autochef
  # Provider-agnostic data objects for per-week plan preferences.
  MealSlotPrefs = Struct.new(:enabled, :servings, :vibe, :note, keyword_init: true)
  DayPrefs      = Struct.new(:meal_type, :dinner, :lunch, keyword_init: true)
  WeekPrefs     = Struct.new(:week_start, :protein_excludes, :freeform_note, :days,
                             keyword_init: true)

  # Interface module — implement #fetch(week_start) -> WeekPrefs or nil
  module WeekPrefsSource
    def fetch(week_start)
      raise NotImplementedError, "#{self.class}#fetch not implemented"
    end
  end
end
