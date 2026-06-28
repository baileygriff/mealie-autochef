# frozen_string_literal: true

require 'active_record'
require 'json'

module Autochef
  module Models
    class WeekPref < ActiveRecord::Base
      self.table_name = 'week_prefs'

      def prefs
        prefs_json.present? ? JSON.parse(prefs_json, symbolize_names: true) : {}
      end

      def prefs=(hash)
        self.prefs_json = hash.to_json
      end
    end
  end
end
