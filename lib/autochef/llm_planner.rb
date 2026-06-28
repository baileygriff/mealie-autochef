# frozen_string_literal: true

require 'json'
require 'httparty'
require_relative 'planner'

module Autochef
  # Wraps the deterministic Planner with an optional Claude LLM refinement step.
  #
  # Flow:
  #   1. Run the deterministic Planner to get a valid, perishability-correct base plan.
  #   2. If llm.enabled, send a prompt to Claude asking it to arrange/rationale the
  #      same recipe pool across the same cook days — output is strict JSON.
  #   3. Validate the JSON against the expected shape. On any failure, fall back to
  #      the deterministic plan with a warning.
  #
  # The LLM never picks *which* recipes are eligible (that's the scorer's job).
  # It annotates assignments with rationales and may reorder across cook days —
  # but it cannot introduce recipe IDs not in the eligible pool.
  class LlmPlanner
    ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages'
    ANTHROPIC_API_VERSION = '2023-06-01'

    # Returned by #plan — wraps a WeekPlan with metadata about how it was produced.
    Result = Struct.new(
      :week_plan,    # Planner::WeekPlan
      :via_llm,      # Boolean
      :llm_error,    # String or nil — set when LLM was attempted but fell back
      keyword_init: true
    )

    def initialize(cfg, planner: nil)
      @cfg     = cfg
      @planner = planner || Planner.new(cfg)
    end

    # Generate a week plan, optionally refined by Claude.
    #
    # pool          — Array of recipe hashes (from MealieClient#eligible_pool),
    #                 each already decorated with "perishability" (Integer).
    # scored_ids    — { recipe_id => Float } from Scorer
    # week_start    — Date (defaults to next Monday)
    # freeform_note — Optional guidance string from the bot/user ("light week, no fish")
    # recent_plans  — Array of prior WeekPlan or plan_json hashes (for context)
    #
    # Returns a Result.
    def plan(pool:, scored_ids:, week_start: nil, freeform_note: nil, recent_plans: [],
             layout_overrides: {}, servings_overrides: {})
      base = @planner.plan(pool: pool, scored_ids: scored_ids,
                           layout_overrides: layout_overrides,
                           servings_overrides: servings_overrides,
                           **week_start ? { week_start: week_start } : {})

      return Result.new(week_plan: base, via_llm: false, llm_error: nil) unless @cfg.llm.enabled

      attempt_llm_refinement(base, pool: pool, freeform_note: freeform_note,
                                   recent_plans: recent_plans)
    end

    private

    def attempt_llm_refinement(base_plan, pool:, freeform_note:, recent_plans:)
      prompt  = build_prompt(base_plan, pool: pool, freeform_note: freeform_note,
                                        recent_plans: recent_plans)
      raw     = call_claude(prompt)
      refined = parse_and_validate(raw, base_plan)
      Result.new(week_plan: refined, via_llm: true, llm_error: nil)
    rescue StandardError => e
      Result.new(week_plan: base_plan, via_llm: false,
                 llm_error: "LLM failed (#{e.class}: #{e.message}) — using deterministic plan.")
    end

    # Build the Claude prompt. Keeps the recipe pool as the system message so
    # it can be prompt-cached across regenerate calls within a session.
    def build_prompt(base_plan, pool:, freeform_note:, recent_plans:)
      recipe_lines = pool.map do |r|
        tags = (r['tags'] || []).map { |t| t['name'] }.join(', ')
        perishability = r['perishability'] || 365
        "- #{r['id']} | #{r['name']} | tags: #{tags} | perishability: #{perishability}d"
      end.join("\n")

      base_lines = base_plan.assignments.map do |a|
        "#{a.day_name} #{a.date.strftime('%Y-%m-%d')}: #{a.recipe_id} (#{a.recipe_name})"
      end.join("\n")

      recent_summary = if recent_plans.any?
                         recent_plans.last(3).map do |p|
                           p.is_a?(Hash) ? p.inspect : p.assignments.map(&:recipe_name).join(', ')
                         end.join(' / ')
                       else
                         'none'
                       end

      note_line = freeform_note.to_s.strip.empty? ? '' : "\nUser note: #{freeform_note}\n"

      system_msg = <<~SYSTEM
        You are a meal planning assistant for a home chef. Your job is to review a
        deterministic base plan and optionally improve it — adding short rationales,
        reordering meals across cook days (perishability order must be preserved),
        or adjusting servings. You MUST NOT introduce recipe IDs not in the eligible pool.

        Eligible recipe pool:
        #{recipe_lines}

        Recent weeks (for context, avoid repetition):
        #{recent_summary}
      SYSTEM

      user_msg = <<~USER
        Base plan for the week of #{base_plan.week_start.strftime('%Y-%m-%d')}:
        #{base_lines}
        #{note_line}
        Return ONLY a JSON object with this exact shape — no prose, no markdown fences:
        {
          "assignments": [
            {
              "date": "YYYY-MM-DD",
              "recipe_id": "<id from pool>",
              "servings": <integer>,
              "meal_type": "<dinner|lunch>",
              "rationale": "<one sentence>"
            }
          ]
        }

        Rules:
        - Keep the same recipe IDs as the base plan (you may reorder across dates).
        - Do not add or remove recipes.
        - Perishability order: more perishable recipes should be earlier in the week.
        - servings must be a positive integer.
        - rationale must be a non-empty string.
      USER

      { system: system_msg, user: user_msg }
    end

    def call_claude(prompt)
      resp = HTTParty.post(
        ANTHROPIC_API_URL,
        headers: {
          'x-api-key' => @cfg.llm.api_key,
          'anthropic-version' => ANTHROPIC_API_VERSION,
          'content-type' => 'application/json'
        },
        body: {
          model: @cfg.llm.model,
          max_tokens: 1024,
          system: prompt[:system],
          messages: [{ role: 'user', content: prompt[:user] }]
        }.to_json,
        timeout: 30
      )

      raise "Anthropic API HTTP #{resp.code}: #{resp.body.to_s.slice(0, 300)}" unless resp.success?

      data = resp.parsed_response
      data.dig('content', 0, 'text') or raise 'Unexpected Anthropic response shape'
    end

    # Parse the LLM text as JSON and reconstruct a WeekPlan from it.
    # Raises on any parse/validation failure (caller handles).
    def parse_and_validate(raw_text, base_plan)
      # Strip markdown code fences that some models emit despite instructions.
      clean = raw_text.strip.gsub(/\A```(?:json)?\s*\n?/, '').gsub(/\n?```\s*\z/, '')
      parsed = JSON.parse(clean)
      llm_assignments = parsed['assignments']
      raise "missing 'assignments' array" unless llm_assignments.is_a?(Array)

      base_ids = base_plan.assignments.map(&:recipe_id).to_set

      # Build a lookup from the base plan for non-LLM fields (name, perishability, etc.)
      base_by_id = base_plan.assignments.to_h { |a| [a.recipe_id, a] }

      new_assignments = llm_assignments.map do |item|
        rid  = item['recipe_id'].to_s
        date = Date.parse(item['date'].to_s)

        raise "unknown recipe_id '#{rid}' not in pool" unless base_ids.include?(rid)
        raise 'invalid servings' unless item['servings'].to_i >= 1

        base = base_by_id[rid]
        Planner::Assignment.new(
          date: date,
          day_name: date.strftime('%a'),
          recipe_id: rid,
          recipe_name: base.recipe_name,
          servings: item['servings'].to_i,
          meal_type: item['meal_type'].to_s,
          makes_leftovers: base.makes_leftovers,
          perishability: base.perishability,
          rationale: item['rationale'].to_s
        )
      end

      # Drop leftover-coverage warnings for cook days that now have a makes-leftovers
      # assignment — the LLM may have placed a better recipe than the deterministic pass.
      covered_dates = new_assignments.select(&:makes_leftovers)
                                     .map { |a| a.date.strftime('%a %b %-d') }.to_set
      warnings = base_plan.warnings.reject do |w|
        w.include?('no makes-leftovers recipe available') &&
          covered_dates.any? { |d| w.start_with?(d) }
      end

      Planner::WeekPlan.new(
        week_start: base_plan.week_start,
        assignments: new_assignments,
        warnings: warnings
      )
    end
  end
end
