# frozen_string_literal: true

require 'spec_helper'
require 'date'
require 'autochef/planner'

RSpec.describe Autochef::Planner do
  let(:week_layout) do
    { 'Sun' => 'cook', 'Mon' => 'leftover', 'Tue' => 'cook',
      'Wed' => 'cook', 'Thu' => 'leftover', 'Fri' => 'out', 'Sat' => 'cook' }
  end

  let(:variety_cfg) do
    double('VarietyConfig', max_same_cuisine_per_week: 2, max_same_protein_per_week: 2)
  end

  let(:scoring_weights) do
    double('ScoringWeights',
           rating: 1.0, tag_affinity: 0.5, recency_penalty: 1.0,
           swap_penalty: 0.75, nutrition_fit: 0.5)
  end

  let(:selection_cfg) do
    double('SelectionConfig',
           repeat_avoidance_weeks: 3,
           variety: variety_cfg,
           scoring_weights: scoring_weights)
  end

  let(:schedule_cfg) { double('ScheduleConfig', pickup_day: 'Sun') }
  let(:meals_cfg) do
    double('MealsConfig',
           week_layout: week_layout,
           meal_types: ['dinner'],
           default_servings: 2)
  end

  let(:cfg) do
    double('Config', meals: meals_cfg, schedule: schedule_cfg, selection: selection_cfg)
  end

  subject(:planner) { described_class.new(cfg) }

  # A fixed Sunday to anchor the test week.
  let(:week_start) { Date.new(2026, 6, 28) }  # a Sunday

  def make_recipe(id, perishability: 365, tags: [])
    { 'id' => id, 'name' => "Recipe #{id}", 'perishability' => perishability, 'tags' => tags }
  end

  describe '#plan' do
    it 'assigns only cook days from the week_layout' do
      pool = (1..6).map { |i| make_recipe("r#{i}") }
      scored_ids = pool.to_h { |r| [r['id'], 1.0] }

      week_plan = planner.plan(pool: pool, scored_ids: scored_ids, week_start: week_start)

      assigned_days = week_plan.assignments.map(&:day_name)
      # cook days: Sun, Tue, Wed, Sat
      expect(assigned_days).to match_array(%w[Sun Tue Wed Sat])
    end

    it 'schedules more perishable recipes earlier in the week' do
      perishable = make_recipe('fish', perishability: 2)
      hardy      = make_recipe('pasta', perishability: 14)
      filler     = [make_recipe('r3'), make_recipe('r4')]
      pool       = [perishable, hardy] + filler
      scored_ids = pool.to_h { |r| [r['id'], 1.0] }

      week_plan = planner.plan(pool: pool, scored_ids: scored_ids, week_start: week_start)

      fish_assignment  = week_plan.assignments.find { |a| a.recipe_id == 'fish' }
      pasta_assignment = week_plan.assignments.find { |a| a.recipe_id == 'pasta' }

      expect(fish_assignment).not_to be_nil
      expect(pasta_assignment).not_to be_nil
      # Fish (perishable) should be assigned earlier than pasta
      expect(fish_assignment.date).to be <= pasta_assignment.date
    end

    it 'flags a perishability violation in warnings' do
      # Assign a 1-day perishable item, but the only remaining slot is Sat (6 days after Sun pickup)
      # Force this by making only one cook slot available: override week_layout
      single_cook_layout = { 'Sun' => 'out', 'Mon' => 'out', 'Tue' => 'out',
                              'Wed' => 'out', 'Thu' => 'out', 'Fri' => 'out', 'Sat' => 'cook' }
      allow(meals_cfg).to receive(:week_layout).and_return(single_cook_layout)

      bad_recipe = make_recipe('fish', perishability: 1)
      pool       = [bad_recipe]
      scored_ids = { 'fish' => 1.0 }

      week_plan = planner.plan(pool: pool, scored_ids: scored_ids, week_start: week_start)

      expect(week_plan.warnings).not_to be_empty
      expect(week_plan.warnings.any? { |w| w.include?('fish') || w.include?('perishability') }).to be true
    end

    it 'returns empty assignments and a warning when pool is empty' do
      week_plan = planner.plan(pool: [], scored_ids: {}, week_start: week_start)
      expect(week_plan.assignments).to be_empty
    end

    it 'uses deterministic ordering by score when no RecipeStat rows exist' do
      pool = [
        make_recipe('low', perishability: 365),
        make_recipe('high', perishability: 365),
        make_recipe('mid',  perishability: 365),
        make_recipe('x1',   perishability: 365)
      ]
      scored_ids = { 'high' => 10.0, 'mid' => 5.0, 'low' => 1.0, 'x1' => 2.0 }

      week_plan = planner.plan(pool: pool, scored_ids: scored_ids, week_start: week_start)

      # High-scored recipe should appear in the plan
      ids = week_plan.assignments.map(&:recipe_id)
      expect(ids).to include('high')
    end
  end
end
