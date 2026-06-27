# frozen_string_literal: true

require 'spec_helper'
require 'autochef/scoring'

RSpec.describe Autochef::Scorer do
  # Minimal config doubles so we don't need a real config.yaml.
  let(:weights) do
    double('ScoringWeights',
           rating: 1.0, tag_affinity: 0.5, recency_penalty: 1.0,
           swap_penalty: 0.75, nutrition_fit: 0.5)
  end
  let(:nutrition) { double('NutritionConfig', enabled: false, target_protein_per_serving_g: 45) }
  let(:cfg) do
    double('Config',
           selection: double('SelectionConfig', scoring_weights: weights),
           nutrition: nutrition)
  end

  subject(:scorer) { described_class.new(cfg) }

  let(:recipe_a) do
    { 'id' => 'recipe-a', 'name' => 'Recipe A',
      'tags' => [{ 'name' => 'cuisine:italian' }, { 'name' => 'protein:chicken' }] }
  end

  let(:recipe_b) do
    { 'id' => 'recipe-b', 'name' => 'Recipe B', 'tags' => [] }
  end

  describe '#update_scores!' do
    it 'writes a score to recipe_stats for each recipe in the map' do
      recipe_map = { 'recipe-a' => recipe_a, 'recipe-b' => recipe_b }
      scorer.update_scores!(recipe_map)

      stat_a = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-a')
      stat_b = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-b')

      expect(stat_a).not_to be_nil
      expect(stat_b).not_to be_nil
      expect(stat_a.score).to be_a(Float)
      expect(stat_b.score).to be_a(Float)
    end

    it 'gives a higher score to a recipe with a higher rating' do
      Autochef::Models::RecipeStat.create!(recipe_id: 'recipe-a', avg_rating: 5.0)
      Autochef::Models::RecipeStat.create!(recipe_id: 'recipe-b', avg_rating: 1.0)

      recipe_map = { 'recipe-a' => recipe_a, 'recipe-b' => recipe_b }
      scorer.update_scores!(recipe_map)

      score_a = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-a').score
      score_b = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-b').score
      expect(score_a).to be > score_b
    end

    it 'penalizes a recipe that has been swapped out many times' do
      Autochef::Models::RecipeStat.create!(recipe_id: 'recipe-a', avg_rating: 4.0, times_swapped_out: 0)
      Autochef::Models::RecipeStat.create!(recipe_id: 'recipe-b', avg_rating: 4.0, times_swapped_out: 5)

      recipe_map = { 'recipe-a' => recipe_a, 'recipe-b' => recipe_b }
      scorer.update_scores!(recipe_map)

      score_a = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-a').score
      score_b = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-b').score
      expect(score_a).to be > score_b
    end

    it 'boosts tag affinity for recipes with positive tag_weights' do
      Autochef::Models::TagWeight.create!(tag: 'cuisine:italian', weight: 2.0)

      recipe_map = { 'recipe-a' => recipe_a, 'recipe-b' => recipe_b }
      scorer.update_scores!(recipe_map)

      score_a = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-a').score
      score_b = Autochef::Models::RecipeStat.find_by(recipe_id: 'recipe-b').score
      expect(score_a).to be > score_b
    end
  end
end
