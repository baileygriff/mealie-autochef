# frozen_string_literal: true

class CreateWeekPrefs < ActiveRecord::Migration[7.2]
  def change
    create_table :week_prefs do |t|
      t.date   :week_start, null: false
      t.text   :prefs_json, null: false, default: '{}'
      t.timestamps
    end
    add_index :week_prefs, :week_start, unique: true
  end
end
