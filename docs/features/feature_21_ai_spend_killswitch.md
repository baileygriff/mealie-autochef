# Feature 21 — AI Spend Kill Switch

> **Status:** Placeholder — spec interview incomplete.
> **Priority:** Medium (safety/protection feature).
>
> **Spec completeness:** Bailey's description is fairly clear on the goal. Key open questions are
> around granularity (per-call vs. per-session vs. per-day), what "killing" means for each command,
> and where debug logs live.

---

## Goal

Monitor LLM token usage and/or request time during any AI-enabled operation. If usage exceeds
configurable thresholds, terminate the AI operation, alert Bailey via Telegram, and log debug
data persistently for review. Protects against runaway AI cost.

---

## Context and background

**What already exists:**

- `safety.rb` — grocery spending cap (`spending_cap_usd`), dry_run flag, deviation_warning
- `config.yaml` `llm:` block — `enabled`, `default_model`, per-tool model overrides (planned in
  Orchestrator Refactor Section 2)
- No current monitoring of LLM API token consumption or request duration

**Natural implementation point:**

The planned `LlmProvider` abstraction (Orchestrator Refactor Section 2) wraps all Anthropic API
calls in a single class. This is the ideal place to add monitoring — one location rather than
patching each of the 4 LLM tools individually.

**This is distinct from the grocery spending cap** in `safety.rb`. That cap checks the Food Lion
cart total. This feature monitors Anthropic API costs.

---

## Known decisions

- Thresholds should be configurable in `config.yaml` alongside AI model settings (Bailey's words)
- Should alert via Telegram when triggered
- Should log debug data to a persistent location for post-hoc review
- Should "kill" the process — not just warn
- Existing `safety.rb` pattern (spending cap, kill switch boolean) is the right mental model

---

## Open questions (interview needed)

**What to measure:**
1. Token usage (input + output tokens per call), request wall-clock time, or both?
2. Should the threshold be per-call (single request) or cumulative per command run
   (e.g. "total tokens used during one `main.rb plan` execution")?
3. Is a per-day or per-month budget useful, or is per-run sufficient?

**What "kill" means:**
4. When triggered during `main.rb plan` — abort the plan? Send a partial plan without LLM
   refinement? Fall back to the deterministic planner?
5. When triggered during `/automap` — stop mapping mid-batch? Map what's done so far?
6. When triggered during `/add` (LlmItemParser) — cancel the add? Fall back to manual form?
7. Should there be a graceful degradation path (fall back to non-LLM behavior) or a hard stop?

**Alerting:**
8. Same Telegram alert pattern as `send_crash_alert`? Or a distinct message format?
9. Should the alert include the token count / cost estimate that triggered it?

**Debug logging:**
10. Where should debug logs go? `data/ai_spend_log.jsonl`? A new DB table?
11. What data to log per triggered event: command name, model, prompt tokens, completion tokens,
    estimated cost, timestamp, which threshold was hit?

**Config structure:**
12. What should the config look like? Rough sketch:
    ```yaml
    llm:
      spend_killswitch:
        enabled: true
        max_tokens_per_call: 10000      # hard stop per single LLM call
        max_tokens_per_run: 50000       # hard stop per command execution
        max_request_time_sec: 30        # hard stop on wall-clock time per call
    ```
    Are these the right knobs? Any others?

---

## Technical notes (preliminary)

- Best implemented in `LlmProvider` (Orchestrator Refactor Section 2) — one enforcement point
- Token counts are returned by the Anthropic API in the response's `usage` field
- Estimated cost = `(input_tokens × input_price + output_tokens × output_price)` — prices per
  model are known and could be hardcoded or configurable
- Wall-clock time can be measured around the API call with `Time.now`
- A `RunBudget` accumulator object could track cumulative usage per command execution and be
  passed through the orchestrator chain
- `data/ai_spend_log.jsonl` (or similar) is a natural persistent log location alongside
  `data/autochef.db` and `data/suggestion_feedback.txt`
