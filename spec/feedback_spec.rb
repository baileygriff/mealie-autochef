# frozen_string_literal: true

require 'spec_helper'
require 'date'
require 'autochef/feedback'

RSpec.describe Autochef::FeedbackApplier do
  subject(:applier) { described_class.new(mealie_client: nil) }

  let(:week_start) { Date.new(2026, 6, 28) }

  # Build a minimal plan_history row.
  def make_plan(week_start, approved: 1)
    plan_json = {
      week_start.iso8601              => { 'recipe_id' => 'r-sun', 'recipe_name' => 'Sunday Dish' },
      (week_start + 2).iso8601       => { 'recipe_id' => 'r-tue', 'recipe_name' => 'Tuesday Dish' }
    }.to_json
    Autochef::Models::PlanHistory.create!(
      week_start: week_start,
      plan_json:  plan_json,
      approved:   approved,
      swaps_json: {}.to_json
    )
  end

  def make_order(week_start, feedback_applied: false)
    Autochef::Models::OrderHistory.create!(
      week_start:       week_start,
      status:           'cart_built',
      run_key:          "autochef-#{week_start.iso8601}",
      feedback_applied: feedback_applied
    )
  end

  describe '#apply' do
    it 'increments times_cooked for each planned recipe' do
      make_plan(week_start)
      order = make_order(week_start)

      result = applier.apply(order)

      expect(result.already_applied).to eq(false)
      expect(result.cooked_count).to eq(2)

      stat_sun = Autochef::Models::RecipeStat.find_by(recipe_id: 'r-sun')
      stat_tue = Autochef::Models::RecipeStat.find_by(recipe_id: 'r-tue')
      expect(stat_sun.times_cooked).to eq(1)
      expect(stat_tue.times_cooked).to eq(1)
    end

    it 'sets last_cooked to the cook date' do
      make_plan(week_start)
      order = make_order(week_start)

      applier.apply(order)

      stat = Autochef::Models::RecipeStat.find_by(recipe_id: 'r-sun')
      expect(stat.last_cooked.to_date).to eq(week_start)
    end

    it 'marks the order as feedback_applied after running' do
      make_plan(week_start)
      order = make_order(week_start)

      applier.apply(order)

      order.reload
      expect(order.feedback_applied).to eq(true)
    end

    it 'is idempotent — second call returns already_applied without re-incrementing' do
      make_plan(week_start)
      order = make_order(week_start, feedback_applied: false)

      applier.apply(order)
      result2 = applier.apply(order)

      expect(result2.already_applied).to eq(true)

      stat = Autochef::Models::RecipeStat.find_by(recipe_id: 'r-sun')
      expect(stat.times_cooked).to eq(1)  # not 2
    end

    it 're-applies when force: true is passed even if already applied' do
      make_plan(week_start)
      order = make_order(week_start, feedback_applied: true)

      result = applier.apply(order, force: true)

      expect(result.already_applied).to eq(false)
      expect(result.cooked_count).to eq(2)
    end

    it 'raises if no approved plan is found for the order week_start' do
      order = make_order(week_start)
      expect { applier.apply(order) }
        .to raise_error(RuntimeError, /No approved plan/)
    end
  end
end
