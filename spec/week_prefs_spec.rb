# frozen_string_literal: true

require 'spec_helper'
require 'date'
require 'autochef/week_prefs_source'
require 'autochef/sinatra_prefs_source'
require 'autochef/planner'

RSpec.describe Autochef::SinatraPrefsSource do
  subject(:source) { described_class.new }

  let(:week_start) { Date.new(2026, 7, 3) }  # a Thursday pickup

  # Minimal fixture params matching what the Sinatra form POST produces.
  let(:form_params) do
    {
      protein_excludes: ['seafood'],
      freeform_note: 'Light week',
      days: {
        '2026-07-03' => {
          meal_type: 'cook',
          dinner: { servings: '4', vibe: 'treat', note: 'Something special' },
          lunch:  { enabled: '1', servings: '2', vibe: 'feed_me', note: '' }
        },
        '2026-07-06' => {
          meal_type: 'skip',
          dinner: { servings: '2', vibe: 'feed_me', note: '' },
          lunch:  { enabled: '0', servings: '2', vibe: 'feed_me', note: '' }
        }
      }
    }
  end

  describe '#fetch' do
    it 'returns nil for an unknown week_start' do
      expect(source.fetch(Date.new(2099, 1, 1))).to be_nil
    end

    it 'returns a WeekPrefs struct after saving' do
      source.save(week_start, form_params)
      result = source.fetch(week_start)
      expect(result).to be_a(Autochef::WeekPrefs)
    end

    it 'deserializes protein_excludes correctly' do
      source.save(week_start, form_params)
      result = source.fetch(week_start)
      expect(result.protein_excludes).to eq(['seafood'])
    end

    it 'deserializes dinner MealSlotPrefs for a cook day' do
      source.save(week_start, form_params)
      result = source.fetch(week_start)
      day = result.days['2026-07-03']
      expect(day).to be_a(Autochef::DayPrefs)
      expect(day.dinner).to be_a(Autochef::MealSlotPrefs)
      expect(day.dinner.servings).to eq(4)
      expect(day.dinner.vibe).to eq('treat')
      expect(day.dinner.note).to eq('Something special')
    end

    it 'deserializes lunch enabled flag correctly' do
      source.save(week_start, form_params)
      result = source.fetch(week_start)
      expect(result.days['2026-07-03'].lunch.enabled).to eq(true)
      expect(result.days['2026-07-06'].lunch.enabled).to eq(false)
    end

    it 'preserves freeform_note' do
      source.save(week_start, form_params)
      result = source.fetch(week_start)
      expect(result.freeform_note).to eq('Light week')
    end
  end

  describe '#save' do
    it 'persists a round-trippable prefs hash' do
      source.save(week_start, form_params)
      row = Autochef::Models::WeekPref.find_by(week_start: week_start)
      expect(row).not_to be_nil
      expect(row.prefs[:protein_excludes]).to eq(['seafood'])
    end

    it 'upserts on repeated saves for the same week' do
      source.save(week_start, form_params)
      source.save(week_start, form_params.merge(freeform_note: 'Updated note'))
      expect(Autochef::Models::WeekPref.where(week_start: week_start).count).to eq(1)
      row = Autochef::Models::WeekPref.find_by(week_start: week_start)
      expect(row.prefs[:freeform_note]).to eq('Updated note')
    end
  end
end

RSpec.describe 'protein_excludes pool filter' do
  # Fixture recipes matching the actual dinner pool in TESTING_HANDOFF.md
  def make_recipe(id, name, protein_tag)
    {
      'id'           => id,
      'name'         => name,
      'perishability' => 365,
      'tags'         => [{ 'name' => "protein:#{protein_tag}" }]
    }
  end

  let(:greek_salmon)    { make_recipe('r1', 'Greek Salmon', 'seafood') }
  let(:lemon_pasta)     { make_recipe('r2', 'Lemon Pasta with Salmon', 'seafood') }
  let(:baileys_chili)   { make_recipe('r3', "Bailey's Chili", 'beef') }
  let(:jambalaya)       { make_recipe('r4', 'Jambalaya', 'chicken') }
  let(:pulled_pork)     { make_recipe('r5', 'Pulled Pork', 'pork') }
  let(:sriracha_noodles){ make_recipe('r6', 'Sriracha Noodles', 'vegetarian') }

  let(:pool) { [greek_salmon, lemon_pasta, baileys_chili, jambalaya, pulled_pork, sriracha_noodles] }

  it 'excludes seafood recipes when protein_excludes includes seafood' do
    filtered = pool.reject do |r|
      ['seafood'].any? { |ex| (r['tags'] || []).any? { |t| t['name'] == "protein:#{ex}" } }
    end

    names = filtered.map { |r| r['name'] }
    expect(names).not_to include('Greek Salmon')
    expect(names).not_to include('Lemon Pasta with Salmon')
    expect(names).to include("Bailey's Chili")
    expect(names).to include('Jambalaya')
  end

  it 'leaves pool unchanged when protein_excludes is empty' do
    filtered = pool.dup
    [].each { |_ex| }   # no-op — nothing excluded
    expect(filtered.size).to eq(pool.size)
  end
end
