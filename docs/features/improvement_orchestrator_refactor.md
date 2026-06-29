# Improvement — Application Orchestrator Refactor

> **Status:** Partially implemented — Section 1 (`errors.rb`) complete. Sections 2–8 pending.
>
> **Lifecycle:** As each section is completed, update the status table below. Once all sections
> are done, remove the per-section specs and replace with actual file paths, interface docs,
> and usage notes.

---

## Goal

Extract every `main.rb` command into a dedicated orchestrator class that wires injectable tool
classes together. One orchestrator per command, independently testable. `main.rb` becomes a
~80-line router.

---

## Design decisions

| Decision | Rationale |
|---|---|
| One orchestrator per command | Independently testable; `PlanOrchestratorSpec` never loads `CartOrchestrator` |
| Constructor injection with defaults | Tests pass stubs; production uses defaults. No registry magic. |
| Tools raise, orchestrators rescue | Each orchestrator defines one clear rescue boundary. |
| LLM provider is per tool instance | Each LLM tool accepts `llm:` kwarg; orchestrators configure from `cfg.llm.models`. |
| Notifier is injectable | `NullNotifier`/`SpyNotifier` in specs; `TelegramNotifier` in production. |
| `main.rb` becomes a thin router | Load config + DB, pick orchestrator, call `run`. |

---

## Section status

| Section | Goal | Status |
|---|---|---|
| 1 | Error taxonomy (`errors.rb`) | ✅ Complete — seventeenth session |
| 2 | LLM provider abstraction | Pending |
| 3 | CartResolver + CartConsolidator | Pending |
| 4 | CartOrchestrator | Pending |
| 5 | Notifier abstraction + BotServer | Pending |
| 6 | ShopOrchestrator | Pending |
| 7 | PlanOrchestrator | Pending |
| 8 | FeedbackOrchestrator + main.rb slim-down | Pending |

**Between every section:** `bundle exec rspec` must be green (same count or higher) +
`bundle exec ruby main.rb check` must return OK before starting the next section.

---

## Target directory structure (new files only)

```
lib/autochef/
├── errors.rb                          ✅ Section 1
├── llm/
│   ├── provider.rb                    # Section 2 — interface module
│   ├── anthropic_provider.rb          # Section 2
│   ├── null_provider.rb               # Section 2
│   └── stub_provider.rb               # Section 2
├── notifiers/
│   ├── notifier.rb                    # Section 5 — interface module
│   ├── telegram_notifier.rb           # Section 5
│   └── null_notifier.rb               # Section 5
├── bot_server.rb                      # Section 5
├── orchestrators/
│   ├── cart_orchestrator.rb           # Section 4
│   ├── shop_orchestrator.rb           # Section 6
│   ├── plan_orchestrator.rb           # Section 7
│   └── feedback_orchestrator.rb       # Section 8
├── cart_resolver.rb                   # Section 3
└── cart_consolidator.rb               # Section 3

spec/
├── support/
│   ├── spy_notifier.rb                # Section 5
│   ├── stub_llm.rb                    # Section 2
│   └── fixture_plan.rb                # Section 7
├── cart_resolver_spec.rb              # Section 3
├── cart_consolidator_spec.rb          # Section 3
├── cart_orchestrator_spec.rb          # Section 4
├── shop_orchestrator_spec.rb          # Section 6
└── plan_orchestrator_spec.rb          # Section 7
```

---

## Section 1 — Error taxonomy (✅ complete)

`lib/autochef/errors.rb` — unified error hierarchy:

```ruby
module Autochef
  class Error < StandardError; end
  class ConfigError   < Error; end
  class LlmError      < Error; end
  class MealieError   < Error; end
  class PlanError     < Error; end
  class ShopError     < Error; end
  class FeedbackError < Error; end
  class CartError     < Error; end
  class SessionExpiredError < CartError
    attr_reader :reason
    def initialize(reason)
      @reason = reason  # "kasada_challenge" | "login_required"
      super("Cart session expired: #{reason}")
    end
  end
  class SpendingCapError < CartError
    attr_reader :total, :cap
    def initialize(total:, cap:)
      @total, @cap = total, cap
      super("Cart total $#{total} exceeds cap $#{cap}")
    end
  end
end
```

---

## Section 2 — LLM provider abstraction

**Goal:** Extract all Anthropic API calls into a single class behind an interface. Each LLM tool
accepts `llm:` kwarg so tests can inject a stub with no API key needed.

**`lib/autochef/llm/provider.rb`:**
```ruby
module Autochef::Llm
  module Provider
    def complete(system:, user:, max_tokens: 1024)
      raise NotImplementedError
    end
  end
end
```

**`lib/autochef/llm/anthropic_provider.rb`:** Accepts `model:` at init. Wraps
`Anthropic::Messages.create`. Raises `Autochef::LlmError` on any API failure.

**`lib/autochef/llm/null_provider.rb`:** `complete(...)` returns `nil`. Used when
`cfg.llm.enabled == false`.

**`lib/autochef/llm/stub_provider.rb`:** Initialized with a canned response string.
`complete(...)` returns it unconditionally. Optional `strict: true` mode records calls for specs.

**`config.yaml` additions:**
```yaml
llm:
  enabled: true
  default_model: "claude-haiku-4-5-20251001"
  models:
    planner:          "claude-sonnet-4-6"
    qty_consolidator: "claude-haiku-4-5-20251001"
    recipe_mapper:    "claude-haiku-4-5-20251001"
    item_parser:      "claude-haiku-4-5-20251001"
```

**Each LLM tool gains `llm:` kwarg:**
```ruby
def initialize(cfg, llm: nil)
  @llm = llm || Autochef::Llm::AnthropicProvider.new(
    model: cfg.llm.models&.planner || cfg.llm.default_model
  )
end
```

**Files:** `lib/autochef/llm/provider.rb`, `anthropic_provider.rb`, `null_provider.rb`,
`stub_provider.rb` (all new); `spec/support/stub_llm.rb` (new); `config.yaml`; `config.rb`;
`llm_planner.rb`, `llm_qty_consolidator.rb`, `llm_recipe_mapper.rb`, `llm_item_parser.rb`.

**Success:** All specs green. No spec requires `ANTHROPIC_API_KEY`.

---

## Section 3 — CartResolver + CartConsolidator

**(Also Step 1 of the Cart Builder Package Refactor — implement these together.)**

**`lib/autochef/cart_resolver.rb`:**
```ruby
module Autochef
  class CartResolver
    # Resolves Mealie shopping list items to cart search terms.
    # Returns array of { search_term:, default_qty:, pack_unit:, skipped: }
    # Returns nil for __skip__ sentinels. Raises CartError if product_map is empty.
    def resolve(mealie_items); end
  end
end
```

**`lib/autochef/cart_consolidator.rb`:**
```ruby
module Autochef
  class CartConsolidator
    def initialize(llm: nil)
      @llm = llm   # nil → skip LLM rationalization pass
    end
    # Enhancement 1: dedup by search_term, sum quantities.
    # Enhancement 2: LLM rationalization of pack sizes (if @llm present).
    # Returns { items: [...], log: [...] }
    def consolidate(resolved_items); end
  end
end
```

**Tests:** `spec/cart_resolver_spec.rb` (ProductMap lookup hit, `__skip__` exclusion, missing
entry), `spec/cart_consolidator_spec.rb` (dedup + qty sum; rationalization with `StubProvider`).

---

## Section 4 — CartOrchestrator

```ruby
module Autochef::Orchestrators
  class CartOrchestrator
    def initialize(cfg, db,
                   resolver:     CartResolver.new,
                   consolidator: CartConsolidator.new,
                   cart_client:  CartClient.new(cfg),
                   notifier:     nil)
      @cfg, @db     = cfg, db
      @resolver     = resolver
      @consolidator = consolidator
      @cart_client  = cart_client
      @notifier     = notifier || Notifiers::TelegramNotifier.new(cfg)
    end

    def run(force: false)
      items        = load_shopping_items
      resolved     = @resolver.resolve(items)
      cart_items   = resolved.reject { |i| i[:skipped] }
      skipped      = resolved.select { |i| i[:skipped] }
      consolidated = @consolidator.consolidate(cart_items)
      result       = @cart_client.build_cart(consolidated, force: force)

      case result[:status]
      when "cart_built"      then @notifier.send_cart_ready(result, skipped_items: skipped)
      when "session_expired" then raise SessionExpiredError.new(result[:abort_reason])
      when "aborted"         then @notifier.send_cart_aborted(result)
      end

    rescue SessionExpiredError => e
      @notifier.send_session_expired_alert(e.reason)
    rescue SpendingCapError => e
      @notifier.send_cart_aborted({ abort_reason: e.message })
    rescue => e
      @notifier.send_crash_alert("build-cart", e)
      raise
    end
  end
end
```

**Tests:** `spec/cart_orchestrator_spec.rb` — `StubCartClient` returning each status variant;
`SpyNotifier` verifies correct send method called for each path.

---

## Section 5 — Notifier abstraction + BotServer

**Goal:** Define a Notifier interface so orchestrators accept `notifier:` kwarg. Split
`notify.rb`'s polling loop into a separate `BotServer` class.

| Concern | Moves to |
|---|---|
| Send methods (`send_draft`, `send_cart_ready`, etc.) | `lib/autochef/notifiers/telegram_notifier.rb` |
| Polling loop + inline button dispatch | `lib/autochef/bot_server.rb` |
| Interface definition | `lib/autochef/notifiers/notifier.rb` |

**`SpyNotifier`** (`spec/support/spy_notifier.rb`): records all calls via `method_missing`;
`received?(method_name)` for assertions.

**`lib/autochef/notify.rb`** becomes a thin backwards-compat shim during transition, then removed.

**Success:** `main.rb serve` starts bot and Sinatra form exactly as before.

---

## Section 6 — ShopOrchestrator

Extracts `cmd_shop` and `cmd_automap` from `main.rb`. Stubs `MealieClient` and `LlmRecipeMapper`
in specs. `spec/shop_orchestrator_spec.rb`.

---

## Section 7 — PlanOrchestrator

Extracts `cmd_plan`. Wires `Scorer`, `Planner`, `LlmPlanner`. LLM model for planning is Sonnet
(`cfg.llm.models&.planner`). `spec/plan_orchestrator_spec.rb` uses `StubProvider` and
`SpyNotifier`; `spec/support/fixture_plan.rb` provides canned plan history.

---

## Section 8 — FeedbackOrchestrator + main.rb slim-down

Extracts `cmd_feedback`. Then reduces `main.rb` to a pure router (~80 lines):

```ruby
case ARGV[0]
when "plan"       then Autochef::Orchestrators::PlanOrchestrator.new(cfg, db).run
when "shop"       then Autochef::Orchestrators::ShopOrchestrator.new(cfg, db).run
when "automap"    then Autochef::Orchestrators::ShopOrchestrator.new(cfg, db).run_automap
when "build-cart" then Autochef::Orchestrators::CartOrchestrator.new(cfg, db).run(force: ARGV.include?("--force"))
when "feedback"   then Autochef::Orchestrators::FeedbackOrchestrator.new(cfg, db).run
when "serve"      then Autochef::BotServer.new(cfg, db).start
when "check"      then run_check(cfg, db)
when "sync"       then run_sync(cfg, db)
when "backup"     then run_backup(cfg, db)
when "budget"     then run_budget(cfg, db)
else puts "Unknown command: #{ARGV[0]}"; exit 1
end
```
