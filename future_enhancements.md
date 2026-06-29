# Future Enhancements — Mealie AutoChef

**Rule: address feedback and improvements first, then new features.**
When asked "what's next," pick the next unchecked item from the Feedback section before moving to New Features.

---

## Feedback / Improvements

Items 1–4 completed in the ninth session (2026-06-28). See [testing_feedback.md](testing_feedback.md) § ninth session for details.

- ✅ Enhancement 2 — LLM Quantity Consolidation (`lib/autochef/llm_qty_consolidator.rb`)
- ✅ Telegram UX: Food Lion Markdown link, `/shop` command, screenshot as photo
- ✅ `est_total` populated in `cart.py` output
- ✅ Crash alert on plan failure (`Notifier.send_crash_alert`, method-level rescue in `cmd_plan`)
- ✅ `/add` multi-item LLM flow — `LlmItemParser`, preview/confirm/edit/cancel, cart rebuild (twelfth session)
- ✅ Automap Telegram report reformatted — two sections: Grocery additions (bullet, qty/unit) + Pantry skips (compact comma list) (twelfth session)
- ✅ Previous Purchases cart optimization — `add_from_previous_purchases` in `cart_builder/cart.py`; 66 cards loaded, 3/24 matched from PP, 21 via search; verified end-to-end eighteenth session ($102.86, 0 flagged)
- ✅ Session Expiry Detection (Option 1) — `detect_session_state()` in `cart.py`; returns `"session_expired"` status to main.rb; Telegram alert with `[✅ Session Refreshed → Rebuild Cart]` inline button; `callback_session_refresh` spawns build-cart --force in background thread
- 🗂️ CapSolver Kasada Auto-solving (Option 2) — see spec below
- 🗂️ Cart Builder Package Refactor — see spec below (supersedes earlier "Modular Testability Refactor"; includes Ruby CartResolver/CartConsolidator + full Python provider abstraction)
- 🗂️ Application Orchestrator Refactor — see spec below (one orchestrator per command, constructor-injected tools, per-function LLM model config, Notifier interface, BotServer extraction)

---

## Feedback / Improvements (pending)

### CapSolver Kasada Auto-solving (Option 2)

**Goal:** Make the Food Lion cart build fully hands-off by automatically solving Kasada bot-detection challenges without any manual browser interaction. Complements Option 1 (session expiry detection) — Option 2 handles Kasada challenges; Option 1 handles actual login expiry.

**Background — two distinct failure modes:**

| Mode | What happened | What fixes it |
|---|---|---|
| `kasada_challenge` | Kasada's bot-detection showed a challenge page | CapSolver can auto-solve → no human needed |
| `login_required` | Session cookie genuinely expired; Food Lion redirected to sign-in | CapSolver cannot help → must re-login manually (Option 1 alert) |

Option 2 only fires for `kasada_challenge`. If the reason is `login_required`, it falls through to the Option 1 Telegram alert regardless of whether CapSolver is configured.

**Why not FlareSolverr (already on Unraid)?** FlareSolverr is Cloudflare-specific (CF_Clearance, Turnstile). Food Lion uses Kasada — a different vendor with an incompatible challenge protocol. FlareSolverr has no Kasada support.

**Why CapSolver:** Has an explicit Kasada task type (`AntiKasadaTask`), official Python SDK (`capsolver`), and the cost at weekly frequency is negligible (~$0.001/solve).

---

**Trigger:** Automatic when `CAPSOLVER_API_KEY` is set in `.env`. No config.yaml toggle needed — remove the key to disable.

**Failure behavior:** If CapSolver fails (API down, balance exhausted, bad token, timeout), fall back to the Option 1 Telegram alert — same `[✅ Session Refreshed → Rebuild Cart]` button flow. Cart build is deferred, not lost.

---

**Implementation (in order):**

1. **Install CapSolver Python SDK**
   ```
   # Add to cart_builder/requirements.txt
   capsolver>=1.0.0
   # Then: source .venv/bin/activate && pip install -r cart_builder/requirements.txt
   ```

2. **Add to `.env`**
   ```
   CAPSOLVER_API_KEY=CAP-xxxxxxxxxxxxxxxxxxxxxxxx
   ```

3. **`cart_builder/cart.py` — new `solve_kasada_challenge(page)` function**
   ```python
   import capsolver

   def solve_kasada_challenge(page: Page) -> bool:
       """
       Attempt to solve a Kasada challenge via CapSolver.
       Returns True if solved and page is past the challenge, False otherwise.
       """
       api_key = os.environ.get("CAPSOLVER_API_KEY", "")
       if not api_key:
           return False

       capsolver.api_key = api_key
       try:
           log("  CapSolver: solving Kasada challenge...")
           solution = capsolver.solve({
               "type": "AntiKasadaTask",
               "pageURL": page.url,
               "pageAction": "pta-handle-checkout",
           })
           # Inject the solution token into the page
           page.evaluate(f"window.__kpsdk_answer = '{solution.get('token', '')}'")
           page.reload(wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
           pace(2000)
           # Re-check session state after reload
           return detect_session_state(page) == "valid"
       except Exception as e:
           log(f"  CapSolver: failed — {e}")
           return False
   ```

   Note: The exact CapSolver task type and token injection method for Kasada should be verified at implementation time against the current CapSolver docs (https://docs.capsolver.com). Kasada's client-side API changes periodically.

4. **`run_build_cart()` — attempt solve before returning `session_expired`**
   ```python
   session_state = detect_session_state(page)
   if session_state == "kasada_challenge":
       log("Kasada challenge detected — attempting CapSolver auto-solve...")
       if solve_kasada_challenge(page):
           log("  CapSolver: solved successfully — continuing build")
           session_state = "valid"
       else:
           log("  CapSolver: solve failed — falling back to manual refresh alert")
   if session_state != "valid":
       return make_output("session_expired", abort_reason=session_state)
   ```

5. **`main.rb` / `notify.rb`:** No changes needed — the `session_expired` fallback path from Option 1 handles the CapSolver failure case automatically.

---

**CapSolver setup instructions (do this when implementing):**

1. Go to https://capsolver.com and create an account
2. Top up balance — $5 is enough for years of weekly use at ~$0.001/solve
3. Go to Dashboard → API Key → copy your key
4. Add `CAPSOLVER_API_KEY=CAP-your-key-here` to `.env`
5. `source .venv/bin/activate && pip install capsolver`
6. Test: `python3 -c "import capsolver; capsolver.api_key='CAP-your-key'; print(capsolver.balance())"`

**Unraid note:** `CAPSOLVER_API_KEY` goes in the Docker env vars (same as the other secrets). No VNC or display needed — CapSolver's solve happens over HTTPS, not in the browser.

---

**Key files to touch:**
- `cart_builder/requirements.txt` — add `capsolver>=1.0.0`
- `cart_builder/cart.py` — `solve_kasada_challenge()`, update `run_build_cart()` logic
- `.env` / `.env.example` — `CAPSOLVER_API_KEY`

---

### Cart Builder Package Refactor

> **Supersedes** the earlier "Modular Testability Refactor" stub. The Ruby-side extractions (CartResolver, CartConsolidator) are preserved as Step 1 below; the Python-side refactor is now a full provider-abstraction redesign.

**Goal:** Restructure `cart_builder/` into a proper Python package that separates provider-specific DOM code (Food Lion / Instacart) from the general cart-building workflow. Each layer is independently testable. Adding support for a second grocery store should require only writing a new provider class — not touching the workflow, the Ruby integration, or the CLI contract.

---

#### Design decisions (fixed — don't revisit without good reason)

| Decision | Rationale |
|---|---|
| Ruby/Python JSON contract is unchanged | `cart.py` still reads stdin, writes stdout. Ruby doesn't need to know about the internal restructure. |
| Coarse provider interface (5 methods) | Easy to implement a new provider. Individual DOM steps (search, click-add) are private to the provider — only the workflow boundary matters. |
| Provider owns the browser session | `Page`, `BrowserContext`, `Browser` are internal to the provider. The workflow never touches Playwright objects directly. |
| `SessionExpiredError` crosses the boundary as an exception | Keeps method signatures clean — `navigate_to_store` either succeeds or raises. The workflow catches and converts to `session_expired` output. |
| Provider-owned slot selection | `select_slot(pref)` is on the provider. Providers that don't have slot pickers return `None`. |
| Previous Purchases is provider-internal | `add_items()` handles PP-first logic internally. Workflow just calls `add_items(items)` and gets back `(added, flagged)`. |
| No Playwright types in `base.py` | The ABC is library-agnostic — a future provider could use Selenium or httpx without touching `base.py`. |

---

#### Package structure (target state)

```
cart_builder/
├── __init__.py
├── cart.py               # CLI entrypoint — Ruby still calls 'python3 cart_builder/cart.py'
├── base.py               # GroceryProvider ABC + CartItem/CartSummary dataclasses + SessionExpiredError
├── workflow.py           # CartWorkflow — provider-agnostic orchestration
├── providers/
│   ├── __init__.py
│   ├── food_lion.py      # FoodLionProvider — all Food Lion / Instacart DOM code
│   └── fixture.py        # FixtureProvider — static data, no browser, for tests
├── tests/
│   ├── __init__.py
│   ├── test_workflow.py  # tests CartWorkflow against FixtureProvider — no browser
│   ├── test_food_lion.py # @pytest.mark.live — requires real Chrome + auth state
│   └── fixtures/
│       ├── sample_input.json
│       └── sample_summary.json
├── probe_pp.py           # diagnostic tool for PP selector investigation (already exists)
└── README.md             # package docs: provider contract, how to add a provider, how to run tests
```

---

#### `base.py` — core types and provider contract

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class CartItem:
    search_term: str
    default_qty: int
    pack_unit: Optional[str] = None


@dataclass
class CartSummary:
    total: Optional[float]
    item_count: int
    pickup_slot: Optional[str]
    flagged_items: list[str]
    screenshot_path: Optional[str]
    previous_purchases_stats: Optional[dict]  # None when not applicable


class SessionExpiredError(Exception):
    """Raised by navigate_to_store() when the saved session is invalid."""
    def __init__(self, reason: str):
        self.reason = reason  # "kasada_challenge" | "login_required"
        super().__init__(reason)


class GroceryProvider(ABC):
    """
    Abstract base for grocery store cart automation providers.

    Each provider is responsible for:
      - Maintaining its own browser/page state internally
      - Implementing the 5 methods below
      - Raising SessionExpiredError from navigate_to_store() if session is bad

    The workflow (CartWorkflow) calls these methods in order and handles the
    JSON output contract with the Ruby side. Providers never write to stdout.

    To add a new grocery store:
      1. Create cart_builder/providers/your_store.py
      2. Subclass GroceryProvider and implement all 5 abstract methods
      3. Register in cart.py's PROVIDER_MAP
      See README.md for a full walkthrough.
    """

    @abstractmethod
    def navigate_to_store(self, store_name: str) -> None:
        """
        Open the store and confirm the session is valid.
        Raises SessionExpiredError if Kasada challenge or login redirect detected.
        """

    @abstractmethod
    def clear_cart(self) -> int:
        """Remove all items currently in the cart. Returns the count removed."""

    @abstractmethod
    def select_slot(self, pickup_window_pref: str) -> Optional[str]:
        """
        Configure the pickup or delivery slot.
        Returns the confirmed slot string (e.g. 'Thu 5:00–6:00 PM') or None
        if the store doesn't use slot selection or no matching slot was found.
        """

    @abstractmethod
    def add_items(self, items: list[CartItem]) -> tuple[list[CartItem], list[str]]:
        """
        Add items to the cart. Providers may use any strategy (e.g. Previous
        Purchases first, then search-based fallback).

        Returns:
          added:   CartItems successfully added to the cart
          flagged: search_term strings for items that couldn't be added
        """

    @abstractmethod
    def capture_summary(self, run_key: str) -> CartSummary:
        """
        Capture the final cart state: total, screenshot, slot, flagged items.
        Providers that tracked previous_purchases_stats during add_items()
        should surface them here.
        """
```

---

#### `workflow.py` — CartWorkflow

Provider-agnostic. Never imports Playwright. Handles:
- Calling provider methods in order
- Catching `SessionExpiredError` → `session_expired` output
- Spending cap check after summary
- Building the final JSON output dict (same structure as today's `make_output()`)

```python
class CartWorkflow:
    def __init__(self, provider: GroceryProvider):
        self.provider = provider

    def run(self, payload: dict) -> dict:
        store_name       = payload.get("store_name", "")
        pickup_pref      = payload.get("pickup_window_pref", "")
        spending_cap     = payload.get("spending_cap_usd")
        dry_run          = payload.get("dry_run", True)
        run_key          = payload.get("run_key", "unknown")
        raw_items        = payload.get("items", [])

        if not raw_items:
            return make_output("aborted", abort_reason="No items provided")

        items = [CartItem(**i) for i in raw_items]

        try:
            self.provider.navigate_to_store(store_name)
        except SessionExpiredError as e:
            return make_output("session_expired", abort_reason=e.reason)

        self.provider.clear_cart()
        slot = self.provider.select_slot(pickup_pref)
        added, flagged = self.provider.add_items(items)
        summary = self.provider.capture_summary(run_key)

        if spending_cap and summary.total and summary.total > spending_cap:
            return make_output(
                "aborted",
                abort_reason=f"Cart total ${summary.total:.2f} exceeds cap ${spending_cap:.2f}",
                flagged_items=flagged,
            )

        return make_output(
            "cart_built",
            est_total=summary.total,
            cart_total=summary.total,
            pickup_slot=summary.pickup_slot or slot,
            flagged_items=flagged,
            screenshot_path=summary.screenshot_path,
            previous_purchases_stats=summary.previous_purchases_stats,
        )
```

---

#### `providers/food_lion.py` — FoodLionProvider

All existing `cart.py` code moves here as class methods. Selector constants become class-level attributes. The internal helpers (`_navigate_to_previous_purchases`, `_collect_prev_purchase_items`, `_match_score`, etc.) stay as private methods.

Key method mapping from existing functions:

| Existing function(s) | FoodLionProvider method |
|---|---|
| `navigate_to_store()` + `detect_session_state()` + `dismiss_modals()` | `navigate_to_store()` — raises `SessionExpiredError` on bad session |
| `clear_cart()` | `clear_cart()` |
| `set_pickup_mode()` + `select_pickup_slot()` | `select_slot()` |
| `add_from_previous_purchases()` + `add_item_to_cart()` loop | `add_items()` — PP pass first, search fallback |
| `capture_cart_summary()` + screenshot | `capture_summary()` |

The provider opens and closes its own `sync_playwright` context in `__init__` / `__del__` or via a context manager. A `with FoodLionProvider(...) as p:` pattern is clean and matches Playwright's own API.

---

#### `providers/fixture.py` — FixtureProvider

No browser. Returns pre-canned data. Used exclusively by `test_workflow.py`.

```python
class FixtureProvider(GroceryProvider):
    """Static provider for testing CartWorkflow without a browser."""

    def navigate_to_store(self, store_name: str) -> None:
        pass  # always succeeds

    def clear_cart(self) -> int:
        return 3  # pretend 3 items were cleared

    def select_slot(self, pref: str) -> Optional[str]:
        return "Thu 5:00–6:00 PM"

    def add_items(self, items):
        # All items succeed except any with search_term == "FLAGGED"
        added   = [i for i in items if i.search_term != "FLAGGED"]
        flagged = [i.search_term for i in items if i.search_term == "FLAGGED"]
        return added, flagged

    def capture_summary(self, run_key: str) -> CartSummary:
        return CartSummary(
            total=89.42,
            item_count=5,
            pickup_slot="Thu 5:00–6:00 PM",
            flagged_items=[],
            screenshot_path=None,
            previous_purchases_stats={"available": 12, "matched": 3, "search_adds": 2},
        )
```

A `SessionExpiredFixtureProvider` variant raises `SessionExpiredError("kasada_challenge")` from `navigate_to_store`, letting `test_workflow.py` verify the `session_expired` output path.

---

#### `cart.py` — CLI entrypoint (after refactor)

Slim. Parses args, picks provider, wires to workflow, prints output.

```python
PROVIDER_MAP = {
    "food_lion": FoodLionProvider,
    # "kroger": KrogerProvider,  # future
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--login",   action="store_true")
    parser.add_argument("--fixture", metavar="FILE", help="Run against fixture JSON, no browser")
    parser.add_argument("--provider", default="food_lion", choices=PROVIDER_MAP)
    args = parser.parse_args()

    if args.login:
        run_login()
        return

    payload = json.load(sys.stdin)

    if args.fixture:
        provider = FixtureProvider.from_file(args.fixture)
    else:
        provider = PROVIDER_MAP[args.provider](auth_state_path=AUTH_STATE_PATH)

    result = CartWorkflow(provider).run(payload)
    print(json.dumps(result))
```

`--fixture` accepts a JSON file in the same shape as the stdin payload. Useful for verifying the JSON contract and workflow logic without Chrome.

---

#### `cart_builder/README.md` — package documentation

Covers:
- Package layout and what each file does
- The `GroceryProvider` contract (copy from `base.py` docstring, with examples)
- How to add a new grocery store provider (step-by-step: create file, subclass, implement 5 methods, register in `PROVIDER_MAP`)
- How to run tests: `pytest cart_builder/tests/test_workflow.py` (no browser); `pytest -m live cart_builder/tests/` (requires auth state)
- How to run probe tools: `python3 cart_builder/probe_pp.py`
- The Ruby/Python JSON contract (input schema, output schema) — so a future provider author knows what the workflow expects in and what it must produce out

---

#### Test strategy

| Test file | What it covers | Browser needed? |
|---|---|---|
| `cart_builder/tests/test_workflow.py` | CartWorkflow routing: session_expired, spending_cap abort, flagged items, successful cart_built | No — uses FixtureProvider |
| `cart_builder/tests/test_workflow.py` | `SessionExpiredFixtureProvider` → confirms `session_expired` output shape | No |
| `cart_builder/tests/test_food_lion.py` | `@pytest.mark.live` — FoodLionProvider.navigate_to_store, clear_cart, etc. against live site | Yes — run manually |

Run workflow tests after any change to `workflow.py` or `base.py`:
```bash
source .venv/bin/activate && pytest cart_builder/tests/test_workflow.py -v
```

---

#### Migration order (implement in this sequence)

**Step 1 — Ruby side (independent, do first):**
- Extract `resolve_cart_item` → `lib/autochef/cart_resolver.rb`
- Extract Enhancement 1 + 2 consolidation → `lib/autochef/cart_consolidator.rb`
- Delegate from `main.rb` (no behavior change)
- Add `spec/cart_resolver_spec.rb`, `spec/cart_consolidator_spec.rb`

**✅ Step 2 — Python: create package skeleton (seventeenth session):**
- `cart_builder/__init__.py` created
- `cart_builder/base.py` created — `CartItem`, `CartSummary`, `SessionExpiredError`, `GroceryProvider` ABC
- `cart_builder/providers/__init__.py` created
- `cart_builder/tests/__init__.py` + fixture JSON files created
- No behavior change — `cart.py` still works as-is

**Step 3 — Python: extract FoodLionProvider:**
- Create `providers/food_lion.py` with `FoodLionProvider` class
- Move all selector constants, helper functions, and the five workflow functions into class methods
- Update `cart.py` to import and use `FoodLionProvider` — no behavior change
- Verify: `bundle exec ruby main.rb build-cart --force` still works

**Step 4 — Python: extract CartWorkflow:**
- Create `workflow.py` with `CartWorkflow` class built from the body of `run_build_cart`
- Update `cart.py` entrypoint to wire `FoodLionProvider` + `CartWorkflow`
- Verify: `bundle exec ruby main.rb build-cart --force` still works

**Step 5 — Python: FixtureProvider + tests + `--fixture` flag:**
- Create `providers/fixture.py` with `FixtureProvider` and `SessionExpiredFixtureProvider`
- Write `tests/test_workflow.py`
- Add `--fixture` arg to `cart.py`
- Run `pytest cart_builder/tests/test_workflow.py` — should pass with no browser

**Step 6 — Documentation:**
- Write `cart_builder/README.md`
- Update `HANDOFF.md` to reflect the new package structure

---

**Key files to touch:**
- `cart_builder/__init__.py` (new)
- `cart_builder/base.py` (new)
- `cart_builder/workflow.py` (new)
- `cart_builder/providers/__init__.py` (new)
- `cart_builder/providers/food_lion.py` (new — receives all current cart.py code)
- `cart_builder/providers/fixture.py` (new)
- `cart_builder/tests/` (new directory)
- `cart_builder/cart.py` (slimmed to CLI entrypoint only)
- `cart_builder/README.md` (new)
- `lib/autochef/cart_resolver.rb` (new)
- `lib/autochef/cart_consolidator.rb` (new)
- `main.rb` — delegate to new Ruby classes
- `spec/cart_resolver_spec.rb` (new)
- `spec/cart_consolidator_spec.rb` (new)

---

### Application Orchestrator Refactor

Applies the same modularity and testability principles from the Cart Builder Package Refactor to the Ruby application layer. Each `main.rb` command becomes a dedicated orchestrator class that wires injectable tool classes together. Implemented one section at a time — run the full spec suite after each section before moving on.

**Note:** Section 3 here (CartResolver + CartConsolidator) corresponds to Step 1 of the Cart Builder Package Refactor above. Implement them together.

---

#### Design decisions

| Decision | Rationale |
|---|---|
| One orchestrator per command | Independently testable; `PlanOrchestratorSpec` never loads `CartOrchestrator` |
| Constructor injection with defaults | Tests pass stubs; production uses defaults. No registry magic. |
| Tools raise, orchestrators rescue | Each orchestrator defines one clear rescue boundary per command. Tools stay simple. |
| LLM provider is per tool instance | Each LLM tool accepts an `llm:` kwarg. Orchestrators configure from `cfg.llm.models`. Different tools can use different models. |
| Notifier is injectable | `NullNotifier`/`SpyNotifier` in specs; `TelegramNotifier` in production. No real API calls from tests. |
| `main.rb` becomes a thin router | Load config + DB, pick orchestrator, call `run`. All logic moves out. |

---

#### Target directory structure (new files only)

```
lib/autochef/
├── errors.rb                          # Section 1
├── llm/
│   ├── provider.rb                    # Section 2 — interface module
│   ├── anthropic_provider.rb          # Section 2 — wraps Anthropic API
│   ├── null_provider.rb               # Section 2 — used when llm.enabled: false
│   └── stub_provider.rb               # Section 2 — canned responses for tests
├── notifiers/
│   ├── notifier.rb                    # Section 5 — interface module
│   ├── telegram_notifier.rb           # Section 5 — extracted from notify.rb
│   └── null_notifier.rb               # Section 5 — no-ops for tests
├── bot_server.rb                      # Section 5 — polling loop + callbacks, from notify.rb
├── orchestrators/
│   ├── cart_orchestrator.rb           # Section 4
│   ├── shop_orchestrator.rb           # Section 6
│   ├── plan_orchestrator.rb           # Section 7
│   └── feedback_orchestrator.rb       # Section 8
├── cart_resolver.rb                   # Section 3 — extracted from main.rb
└── cart_consolidator.rb               # Section 3 — extracted from main.rb

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

#### Between every section

After completing each section and before starting the next:

1. `bundle exec rspec` — must be green, same count or higher
2. `bundle exec ruby main.rb check` — must return OK
3. If the section touched a Telegram-dependent flow: run `main.rb serve`, verify bot starts cleanly
4. No partial sections — if a section isn't green, finish it before touching anything else

---

#### Section 1 — Error taxonomy

**Goal:** One canonical place for all application error types. Every subsequent section raises these instead of bare `StandardError` or string messages.

```ruby
# lib/autochef/errors.rb
module Autochef
  class Error < StandardError; end

  class ConfigError   < Error; end    # already raised by config.rb — move require here
  class LlmError      < Error; end    # raised by any LLM tool on API failure
  class MealieError   < Error; end    # raised by mealie_client.rb on API failure
  class PlanError     < Error; end    # raised by planner/scorer on logic failure
  class ShopError     < Error; end
  class FeedbackError < Error; end

  class CartError     < Error; end
  class SessionExpiredError < CartError
    attr_reader :reason
    def initialize(reason)
      @reason = reason          # "kasada_challenge" | "login_required"
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

**Files:** `lib/autochef/errors.rb` (new). Update `config.rb` to `require_relative 'errors'` at the top.

**Tests:** None for this section — error classes are plain structs. Raising specs come with the sections that use them.

**Success:** `bundle exec rspec` green. `require 'autochef/errors'` works in isolation with no other requires.

**✅ Completed seventeenth session (2026-06-28).** `lib/autochef/errors.rb` created; `ConfigError` removed from `config.rb`; `require_relative 'errors'` added. 50/50 specs green.

---

#### Section 2 — LLM provider abstraction

**Goal:** Extract all Anthropic API calls into a single class behind an interface. Each LLM tool accepts an `llm:` kwarg so tests can inject a stub with no API key needed.

**`lib/autochef/llm/provider.rb` — interface:**
```ruby
module Autochef::Llm
  module Provider
    # Returns the response text string, or nil on failure.
    # All implementations must respond to this signature.
    def complete(system:, user:, max_tokens: 1024)
      raise NotImplementedError
    end
  end
end
```

**`lib/autochef/llm/anthropic_provider.rb`:**
- Accepts `model:` at init
- Wraps the existing `Anthropic::Messages.create` call pattern (currently duplicated across all 4 LLM tools)
- Raises `Autochef::LlmError` on any API failure, wrapping the original exception

**`lib/autochef/llm/null_provider.rb`:**
- `complete(...)` returns `nil`
- Used when `cfg.llm.enabled == false`

**`lib/autochef/llm/stub_provider.rb` (also used in `spec/support/stub_llm.rb`):**
- Initialized with a canned response string
- `complete(...)` returns it unconditionally
- Optional `strict: true` mode that records calls for assertion in specs

**`config.yaml` schema addition:**
```yaml
llm:
  enabled: true
  default_model: "claude-haiku-4-5-20251001"
  models:                                        # per-tool overrides
    planner:         "claude-sonnet-4-6"         # complex arrangement reasoning
    qty_consolidator: "claude-haiku-4-5-20251001" # simple arithmetic
    recipe_mapper:   "claude-haiku-4-5-20251001"  # ingredient lookup
    item_parser:     "claude-haiku-4-5-20251001"  # text parsing
```

**Each of the 4 LLM tools gains an `llm:` kwarg:**
```ruby
# before
def initialize(cfg)
  @client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])
  @model  = cfg.llm.model || "claude-haiku-4-5-20251001"
end

# after
def initialize(cfg, llm: nil)
  @llm = llm || Autochef::Llm::AnthropicProvider.new(
    model: cfg.llm.models&.planner || cfg.llm.default_model
  )
end
```

Internal API calls replaced with `@llm.complete(system: ..., user: ...)`. No logic change.

**Files touched:**
- `lib/autochef/llm/provider.rb`, `anthropic_provider.rb`, `null_provider.rb`, `stub_provider.rb` (all new)
- `spec/support/stub_llm.rb` (new)
- `config.yaml` — add `models:` block
- `lib/autochef/config.rb` — parse `llm.models` into a struct
- `lib/autochef/llm_planner.rb`, `llm_qty_consolidator.rb`, `llm_recipe_mapper.rb`, `llm_item_parser.rb` — add `llm:` kwarg

**Tests:** Update any existing LLM tool specs to inject `StubProvider`. Add a `spec/llm_provider_spec.rb` that exercises `NullProvider` and `StubProvider` directly.

**Success:** All specs green. No spec requires `ANTHROPIC_API_KEY` to pass.

---

#### Section 3 — CartResolver + CartConsolidator

**(Also Step 1 of the Cart Builder Package Refactor — implement these together.)**

**Goal:** Extract `resolve_cart_item` and the Enhancement 1+2 consolidation block from `main.rb` into two independently testable classes.

**`lib/autochef/cart_resolver.rb`:**
```ruby
module Autochef
  class CartResolver
    # Resolves a Mealie shopping list item to a cart search term.
    # Returns nil for __skip__ sentinels (pantry items).
    # Raises CartError if the product_map table is empty.
    def resolve(mealie_items)
      # Returns array of { search_term:, default_qty:, pack_unit:, skipped: }
    end
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
    def consolidate(resolved_items)
    end
  end
end
```

**`main.rb`:** The inline resolve+consolidate block in `cmd_build_cart` becomes:
```ruby
resolver     = Autochef::CartResolver.new
consolidator = Autochef::CartConsolidator.new(llm: llm_provider)
resolved     = resolver.resolve(mealie_items)
consolidated = consolidator.consolidate(resolved.reject(&:skipped))
```

**Tests:**
- `spec/cart_resolver_spec.rb` — ProductMap lookup hit, `__skip__` exclusion, missing entry behavior
- `spec/cart_consolidator_spec.rb` — dedup + qty sum without LLM; rationalization with `StubProvider`

**Files touched:** `lib/autochef/cart_resolver.rb`, `lib/autochef/cart_consolidator.rb` (new); `main.rb` (inline block replaced); `spec/cart_resolver_spec.rb`, `spec/cart_consolidator_spec.rb` (new).

**Success:** Specs green. `main.rb build-cart --force` behavior unchanged.

---

#### Section 4 — CartOrchestrator

**Goal:** Extract `cmd_build_cart` from `main.rb` into an orchestrator with a clear error-handling boundary. The first orchestrator to implement — use it to establish the pattern for Sections 6–8.

```ruby
# lib/autochef/orchestrators/cart_orchestrator.rb
module Autochef
  module Orchestrators
    class CartOrchestrator
      def initialize(cfg, db,
                     resolver:     CartResolver.new,
                     consolidator: CartConsolidator.new,
                     cart_client:  CartClient.new(cfg),
                     notifier:     nil)   # caller supplies notifier
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

        result = @cart_client.build_cart(consolidated, force: force)

        case result[:status]
        when "cart_built"     then @notifier.send_cart_ready(result, skipped_items: skipped)
        when "session_expired" then raise SessionExpiredError.new(result[:abort_reason])
        when "aborted"        then @notifier.send_cart_aborted(result)
        end

      rescue SessionExpiredError => e
        @notifier.send_session_expired_alert(e.reason)
      rescue SpendingCapError => e
        @notifier.send_cart_aborted({ abort_reason: e.message })
      rescue => e
        @notifier.send_crash_alert("build-cart", e)
        raise
      end

      private

      def load_shopping_items
        # current Mealie fetch logic from cmd_build_cart
      end
    end
  end
end
```

**`main.rb`:** `cmd_build_cart` becomes:
```ruby
def cmd_build_cart(cfg, db, force: false)
  Autochef::Orchestrators::CartOrchestrator.new(cfg, db).run(force: force)
end
```

**Tests (`spec/cart_orchestrator_spec.rb`):**
- `StubCartClient` returning `{ status: "cart_built", ... }` → verify notifier called with `send_cart_ready`
- `StubCartClient` returning `{ status: "session_expired", abort_reason: "kasada_challenge" }` → verify `send_session_expired_alert` called
- `StubCartClient` returning `{ status: "aborted" }` → verify `send_cart_aborted` called
- `StubCartClient` raising an unexpected error → verify `send_crash_alert` called and error re-raised
- All use `SpyNotifier` — no real Telegram calls

**Files touched:** `lib/autochef/orchestrators/cart_orchestrator.rb` (new); `main.rb`; `spec/cart_orchestrator_spec.rb` (new).

**Success:** Specs green. `main.rb build-cart --force` behavior unchanged.

---

#### Section 5 — Notifier abstraction

**Goal:** Define a Notifier interface so orchestrators accept a `notifier:` kwarg. Introduce `NullNotifier` and `SpyNotifier` for specs. Split `notify.rb`'s polling loop into a separate `BotServer` class.

This is the largest single-file change. `notify.rb` currently does three distinct jobs:

| Concern | Moves to |
|---|---|
| Send methods (`send_draft`, `send_cart_ready`, `send_crash_alert`, etc.) | `lib/autochef/notifiers/telegram_notifier.rb` |
| Polling loop + inline button dispatch | `lib/autochef/bot_server.rb` |
| Interface definition (what callers expect) | `lib/autochef/notifiers/notifier.rb` |

**`lib/autochef/notifiers/notifier.rb` — interface module:**
```ruby
module Autochef::Notifiers
  module Notifier
    # Every send_* method in TelegramNotifier must appear here.
    # Implementations return nil — fire and forget.
    def send_draft(history, note: nil)             = raise NotImplementedError
    def send_cart_ready(result, skipped_items: []) = raise NotImplementedError
    def send_cart_aborted(result)                  = raise NotImplementedError
    def send_session_expired_alert(reason)         = raise NotImplementedError
    def send_automap_report(result)                = raise NotImplementedError
    def send_crash_alert(cmd, error)               = raise NotImplementedError
    def send_shop_complete(plan)                   = raise NotImplementedError
    # ... (full list mirrors all send_* in notify.rb)
  end
end
```

**`lib/autochef/notifiers/telegram_notifier.rb`:** Direct copy of all `send_*` methods from `notify.rb`. No behavior change.

**`lib/autochef/notifiers/null_notifier.rb`:** All methods are `def method_name(*) = nil`.

**`spec/support/spy_notifier.rb`:**
```ruby
class SpyNotifier
  include Autochef::Notifiers::Notifier
  attr_reader :calls

  def initialize
    @calls = Hash.new { |h, k| h[k] = [] }
  end

  def method_missing(name, *args, **kwargs)
    @calls[name] << { args: args, kwargs: kwargs }
    nil
  end

  def received?(method_name)
    @calls.key?(method_name)
  end
end
```

**`lib/autochef/bot_server.rb`:** Extracts the `start_bot` polling loop, callback dispatch (`callback_approve`, `callback_swap`, `callback_session_refresh`, etc.), and `@pending_states` from `notify.rb`. Accepts a `notifier:` for sends.

**`lib/autochef/notify.rb`:** During transition, kept as a thin shim:
```ruby
require_relative 'notifiers/telegram_notifier'
# Backwards compat alias — remove once all callers updated
Autochef::Notifier = Autochef::Notifiers::TelegramNotifier
```
Remove entirely once all orchestrators are updated.

**Files touched:** 4 new files under `lib/autochef/notifiers/`; `lib/autochef/bot_server.rb` (new); `lib/autochef/notify.rb` (becomes shim, then deleted); `spec/support/spy_notifier.rb` (new); all orchestrators updated to accept `notifier:` kwarg.

**Success:** Specs green. `main.rb serve` starts the Telegram bot and Sinatra form exactly as before.

---

#### Section 6 — ShopOrchestrator

**Goal:** Extract `cmd_shop` and `cmd_automap` from `main.rb`.

```ruby
class ShopOrchestrator
  def initialize(cfg, db,
                 mealie:   MealieClient.new(cfg),
                 shopping: Shopping.new(cfg),
                 mapper:   LlmRecipeMapper.new(cfg, llm: ...),
                 notifier: Notifiers::TelegramNotifier.new(cfg))
  end

  def run(plan_id: nil)
    plan = load_approved_plan(plan_id)
    @shopping.build_shopping_list_for(plan)
    run_automap if @cfg.llm.enabled
    @notifier.send_shop_complete(plan)
  rescue MealieError => e
    @notifier.send_crash_alert("shop", e)
    raise
  end

  def run_automap
    @mapper.map_unmapped
    @notifier.send_automap_report(@mapper.last_result)
  rescue LlmError => e
    @notifier.send_crash_alert("automap", e)
    raise
  end
end
```

**Tests (`spec/shop_orchestrator_spec.rb`):** Stub `MealieClient` and `LlmRecipeMapper`. Verify notifier receives the right send call for each path. No live Mealie connection.

**Files touched:** `lib/autochef/orchestrators/shop_orchestrator.rb` (new); `main.rb`; `spec/shop_orchestrator_spec.rb` (new).

**Success:** Specs green. `main.rb shop` and `main.rb automap` behavior unchanged.

---

#### Section 7 — PlanOrchestrator

**Goal:** Extract `cmd_plan` from `main.rb`. Most complex — Scorer, Planner, and LlmPlanner are all wired here, and the LLM model for planning is Sonnet (configured in `cfg.llm.models.planner`).

```ruby
class PlanOrchestrator
  def initialize(cfg, db,
                 scorer:      Scorer.new(cfg),
                 planner:     Planner.new(cfg),
                 llm_planner: LlmPlanner.new(cfg, llm: Llm::AnthropicProvider.new(model: cfg.llm.models&.planner)),
                 notifier:    Notifiers::TelegramNotifier.new(cfg))
  end

  def run(note: nil)
    stats    = @scorer.score_all
    draft    = @planner.build(stats, note: note)
    refined  = @cfg.llm.enabled ? @llm_planner.refine(draft) : draft
    history  = save_draft_plan(refined)
    @notifier.send_draft(history, note: refined.llm_error)
  rescue LlmError => e
    @notifier.send_crash_alert("plan", e)
    raise
  rescue PlanError => e
    @notifier.send_crash_alert("plan", e)
    raise
  end
end
```

**Tests (`spec/plan_orchestrator_spec.rb`):** Stub `Scorer` (returns fixture stats array), stub `LlmPlanner` (via `StubProvider`), use `SpyNotifier`. Verify `send_draft` is called with the right history. Verify `send_crash_alert` is called when `LlmError` is raised.

**Files touched:** `lib/autochef/orchestrators/plan_orchestrator.rb` (new); `main.rb`; `spec/plan_orchestrator_spec.rb` (new); `spec/support/fixture_plan.rb` (new — canned plan history for specs).

**Success:** Specs green. `main.rb plan` generates a plan and sends Telegram draft as before.

---

#### Section 8 — FeedbackOrchestrator + main.rb slim-down

**Goal:** Extract `cmd_feedback`. Then reduce `main.rb` to a pure router.

`FeedbackOrchestrator` is simple — loads order history, runs feedback signals, updates recipe stats, notifies. No unusual error paths.

**`main.rb` final form:**
```ruby
#!/usr/bin/env ruby
require_relative 'lib/autochef'

cfg = Autochef::Config.load!
db  = Autochef::Database.connect!(cfg)

case ARGV[0]
when "plan"        then Autochef::Orchestrators::PlanOrchestrator.new(cfg, db).run
when "shop"        then Autochef::Orchestrators::ShopOrchestrator.new(cfg, db).run
when "automap"     then Autochef::Orchestrators::ShopOrchestrator.new(cfg, db).run_automap
when "build-cart"  then Autochef::Orchestrators::CartOrchestrator.new(cfg, db).run(force: ARGV.include?("--force"))
when "feedback"    then Autochef::Orchestrators::FeedbackOrchestrator.new(cfg, db).run
when "serve"       then Autochef::BotServer.new(cfg, db).start
when "check"       then run_check(cfg, db)      # small enough to stay in main.rb
when "sync"        then run_sync(cfg, db)
when "backup"      then run_backup(cfg, db)
when "budget"      then run_budget(cfg, db)
else puts "Unknown command: #{ARGV[0]}"; exit 1
end
```

**Files touched:** `lib/autochef/orchestrators/feedback_orchestrator.rb` (new); `main.rb` (final slim-down).

**Success:** Specs green. All `main.rb` commands work as before. `main.rb` is under ~80 lines.

---

#### New files summary

```
lib/autochef/errors.rb
lib/autochef/llm/provider.rb
lib/autochef/llm/anthropic_provider.rb
lib/autochef/llm/null_provider.rb
lib/autochef/llm/stub_provider.rb
lib/autochef/notifiers/notifier.rb
lib/autochef/notifiers/telegram_notifier.rb
lib/autochef/notifiers/null_notifier.rb
lib/autochef/bot_server.rb
lib/autochef/cart_resolver.rb
lib/autochef/cart_consolidator.rb
lib/autochef/orchestrators/cart_orchestrator.rb
lib/autochef/orchestrators/shop_orchestrator.rb
lib/autochef/orchestrators/plan_orchestrator.rb
lib/autochef/orchestrators/feedback_orchestrator.rb
spec/support/spy_notifier.rb
spec/support/stub_llm.rb
spec/support/fixture_plan.rb
spec/cart_resolver_spec.rb
spec/cart_consolidator_spec.rb
spec/cart_orchestrator_spec.rb
spec/shop_orchestrator_spec.rb
spec/plan_orchestrator_spec.rb
```

---

### 5. Debug Screenshots

Take screenshots at each meaningful step of the cart build. Keep a rolling window of the last 2 full run directories.

**Screenshots to capture (in order):**
1. After `navigate_to_store` + modal dismissal — confirm we're on the right page
2. After `clear_cart` — confirm cart is empty
3. After `set_pickup_mode` — confirm pickup tab active
4. After each `add_item_to_cart` success — confirm item appeared in cart count
5. After `capture_cart_summary` — the final cart view (same as current `run_key.png`)
6. On any exception — error screenshot (already exists)

**Implementation:**
```python
debug_dir = SCREENSHOT_DIR / run_key
debug_dir.mkdir(parents=True, exist_ok=True)
page.screenshot(path=str(debug_dir / "01_store_loaded.png"))
```

Rolling window: at the start of `run_build_cart()`, list all subdirectories of `SCREENSHOT_DIR` sorted by mtime. If more than 1 exists, delete the oldest.

The final summary screenshot (`run_key.png`) stays as-is for the Telegram notification.

**Env var** `DEBUG_SCREENSHOTS_PATH`: if set, rsync/copy the debug run directory there after completion.

**Key files:**
- `cart_builder/cart.py` — `run_build_cart()`: per-step screenshots, rolling cleanup, optional copy to `DEBUG_SCREENSHOTS_PATH`
- `.env.example` — document `DEBUG_SCREENSHOTS_PATH`

---

### ✅ 6. LLM Assisted Recipe Mapping — completed 2026-06-28 (eleventh session); verified + bug-fixed twelfth session

`lib/autochef/llm_recipe_mapper.rb`, `scripts/auto_map.rb`, `main.rb automap`, `/automap` bot command.
See [testing_feedback.md](testing_feedback.md) § twelfth and eleventh sessions for full details.

Key bug fixed in twelfth session: product_map keys now use the original Mealie note (via numbered items + index echo) rather than the LLM's stripped `ingredient_name`. This ensures `resolve_cart_item` can look them up correctly.

Original spec preserved below for reference.

Replaces the manual `seed_product_map.rb` interactive flow. Claude Haiku suggests `search_term`, `qty`, `unit` for new ingredients, auto-saves them, and generates a Telegram review report. Also flags suspicious existing mappings.

**Triggers:**
- Automatically after a recipe is imported via the `/newrecipes` flow (see spec below)
- Telegram command `/automap` — runs on-demand for any unmapped ingredients in the active shopping list
- `bundle exec ruby scripts/auto_map.rb` — CLI fallback

**What it does:**
1. Fetches unmapped ingredients from the Mealie "Next Order" shopping list (same source as `seed_product_map.rb`)
2. For each: LLM suggests `{search_term, qty, unit, pantry_skip: bool}` given the ingredient name, quantity, unit, recipe name, and serving size
3. Auto-saves all suggestions to `product_map`
4. For existing entries: flags any that look suspicious (qty seems off for serving size, search term too generic, `__skip__` on something that should be real, etc.) — flags go in the report, no auto-overwrite
5. Sends Telegram report: "Mapped 8 new ingredients. Flagged 2 suspicious existing — run `seed_product_map.rb --list` to inspect."

**Scope:** unmapped ingredients are auto-saved; suspicious existing entries are flagged only (Bailey corrects via `seed_product_map.rb --update`).

**Key files:**
- `scripts/auto_map.rb` — new CLI entry point
- `lib/autochef/llm_recipe_mapper.rb` — new: builds context, calls Claude Haiku, parses suggestions, writes to product_map
- `lib/autochef/notify.rb` — new `send_automap_report` method
- `main.rb` — `/automap` Telegram command handler; call `LlmRecipeMapper` after recipe import in `/newrecipes` flow

---

### 7. Cart Review, Auto-Fix + /cart-correction

> **Supersedes** the previous Feature 7 (LLM Cart Review). The core idea is preserved — LLM + screenshot — but this version adds a structured review table sent with the cart-ready message, a one-attempt auto-fix for clear mistakes before notification, and a `/cart-correction` command for human-directed corrections that batch into a full cart rebuild.

---

#### Overview of the full flow

1. `cart.py` builds the cart and returns per-item results (new `items_added` field — see schema below)
2. `main.rb` calls `LlmCartReviewer` with the per-item results + screenshot
3. LLM auto-fixes "happy cases" (one attempt — clear wrong product, wrong variant, obvious bad substitute): calls a targeted cart.py correction session to remove + re-add
4. LLM categorizes all items into the review table
5. Cart-ready Telegram message includes the full review table (see format below)
6. Bailey reviews and sends `/cart-correction` for anything the LLM missed or got wrong
7. Corrections batch in `@pending_states`, user confirms with a button
8. Confirmed corrections update product_map for those items (permanent improvement), then trigger `build-cart --force`
9. After rebuild, a fresh review table and screenshot are sent

---

#### cart.py output schema additions

`cart.py` must return a new `items_added` array in its JSON output. Each entry covers one item that was attempted:

```python
{
  "status": "cart_built",
  # ... existing fields unchanged ...
  "items_added": [
    {
      "search_term": "chicken thighs",           # Ruby-side search term from product_map
      "product_name": "Food Lion Chicken Thighs Bone-In, 4 lbs",  # text from Food Lion page
      "product_qty_description": "4 lbs",        # pack size as shown on product card
      "recipe_qty_requested": "2 lbs",           # from input payload (see below)
      "match_source": "previous_purchases",       # "previous_purchases" | "search"
      "pp_score": 0.85,                          # only present when match_source == "previous_purchases"
      "added": true                              # false if item could not be added
    },
    ...
  ]
}
```

To populate `recipe_qty_requested`, the Ruby-side payload to cart.py must be extended to include the original recipe quantity alongside each search term. This is already available from the shopping list — it's the scaled ingredient quantity from `build_and_push`.

**cart.py input payload extension (per item):**
```python
{
  "search_term": "chicken thighs",
  "default_qty": 1,
  "pack_unit": "pkg",
  "recipe_qty_description": "2 lbs"   # new — human-readable recipe quantity for review
}
```

---

#### `lib/autochef/llm_cart_reviewer.rb` — new class

Single responsibility: receives cart data + screenshot path, calls Claude vision API, returns a `CartReviewResult` struct.

```ruby
module Autochef
  CartReviewResult = Struct.new(
    :auto_corrected,    # Array<Hash> — items the LLM fixed before notification
    :auto_fix_failed,   # Array<Hash> — items LLM tried to fix but couldn't (goes to low_confidence)
    :low_confidence,    # Array<Hash> — items flagged for human review
    :qty_discrepancies, # Array<Hash> — pack qty significantly off from recipe qty
    :high_confidence,   # Array<Hash> — items LLM considers correct
    :correction_attempts, # Integer — how many auto-fix attempts were made
    keyword_init: true
  )

  class LlmCartReviewer
    def initialize(cfg, llm: nil)
      @cfg = cfg
      @llm = llm || Llm::AnthropicProvider.new(model: cfg.llm.models&.cart_reviewer || cfg.llm.default_model)
    end

    # items_added: the items_added array from cart.py output
    # screenshot_path: path to the final cart screenshot
    # Returns CartReviewResult
    def review(items_added:, screenshot_path:)
      # Calls LLM with vision (screenshot) + items_added data
      # LLM categorizes items and identifies auto-fix candidates
      # Performs one auto-fix attempt per flagged "happy case"
      # Returns CartReviewResult
    end
  end
end
```

**LLM prompt context:**
- System: "You are reviewing a grocery cart. Given the cart screenshot and the list of items that were searched and added, identify: (1) items where the wrong product was added (wrong variant, fake substitute, clearly off brand), (2) items where the pack quantity is significantly larger or smaller than the recipe needs, (3) items you're confident are correct. Return structured JSON."
- User: screenshot (vision) + `items_added` JSON
- Model: Claude Sonnet (vision capability needed)

**Auto-fix — "happy cases" only (one attempt each):**

The LLM tags each problem item with an `auto_fix_strategy`:
- `"re_search"` — search term was likely fine, but the wrong result was selected; try re-searching with a more specific term
- `"variant_change"` — right product category, wrong variant (e.g. skin-on vs. skinless); try re-searching with the variant in the term
- `"substitute_rejected"` — clearly wrong product (e.g. imitation vs. real); try re-searching

For each `auto_fix_strategy` item:
1. Pass a targeted correction to cart.py: `{remove_product: "...", replace_search_term: "..."}`
2. cart.py removes the item from the cart, searches for the replacement term, adds first result
3. If add succeeds → item moves to `auto_corrected` in the review result
4. If add fails → item moves to `auto_fix_failed` → surfaces in `low_confidence` section of review table
5. **One attempt only — no retry loops**

Items with `auto_fix_strategy: nil` (ambiguous, not clearly wrong, or uncertain) are never auto-fixed.

---

#### Review table format (Telegram Markdown)

Sent as part of the cart-ready message:

```
*Cart ready ✅*

Total: *$119.45*
Pickup slot: Thu 5:00–6:00 PM

[Open cart in Food Lion To Go](https://www.foodlion.com/shop)

---

*Ingredient Review*

⚠️ *Needs your attention (2 items)*
| Called For | Got |
|---|---|
| chicken thighs | Food Lion Bone-In Skin-On Chicken *Breast* |
| 1 lemon | ReaLemon Lemon Juice (8 fl oz bottle) |

📦 *Quantity notes (3 items)*
| Called For | Got |
|---|---|
| 1/4 cup sugar | Domino Granulated Sugar, 5 lb bag |
| 1 egg | Food Lion Large Eggs, 12-count |
| 1 tbsp olive oil | Pompeian Smooth EVOO, 16 fl oz |

✓ *Auto-corrected (1 item)*
| Originally added | Replaced with |
|---|---|
| Dannon Greek Yogurt Vanilla | Dannon Plain Whole Milk Yogurt (32oz) |

✓ *High confidence (18 items) — tap to expand_
```

Notes:
- High confidence items are collapsed by default (listed in a separate follow-up message if the user asks, or via `/cart-detail`)
- Pantry items already listed as a separate section (existing behavior)
- `auto_fix_failed` items surface in "Needs your attention" with a note: "_(auto-fix attempted — see /cart-detail)_"

---

#### `/cart-correction` command

```
/cart-correction you picked chicken breasts but I want chicken thighs only or nothing
/cart-correction get real lemons instead of the ReaLemon bottle
```

**Flow:**

1. User sends `/cart-correction <free text>`
2. LLM (`LlmItemParser`-style) parses into structured correction(s):
   ```json
   [
     {
       "current_product": "Food Lion Bone-In Skin-On Chicken Breast",
       "action": "replace",
       "replacement_search_term": "chicken thighs",
       "or_nothing": true
     }
   ]
   ```
3. Bot shows a correction preview with [✅ Apply] [✏️ Edit] [➕ Add another] [🔄 Rebuild now] buttons
4. User can batch multiple corrections before rebuilding
5. On **Rebuild**: each correction updates the `ProductMap` entry for that `search_term` (permanent fix), then `build-cart --force` runs
6. After rebuild: fresh cart-ready message with new review table and screenshot

**Why update product_map permanently:**
Corrections improve future builds. If chicken thighs was mapped to a bad search term, fixing it now prevents the same issue next week. If the correction is one-off (e.g. "this week I want thighs, normally breast is fine"), the user can note that in the free-text and the LLM will leave the product_map unchanged.

**Pending state** (in `@pending_states[chat_id]`):
```ruby
{
  action:      :waiting_cart_correction,
  corrections: [{ current_product:, action:, replacement_search_term:, or_nothing:, update_product_map: }],
  run_key:     "2026-06-30-1"
}
```

---

#### Migration order

**Step 1 — cart.py output extension:**
- Add `items_added` array to `run_build_cart()` return value
- Track `product_name`, `product_qty_description` after each `add_item_to_cart()` call
- Extend input payload schema to accept `recipe_qty_description` per item
- Update `cart_client.rb` to pass `recipe_qty_description` from shopping list data
- Verify: `build-cart --force` still works; `items_added` appears in JSON output

**Step 2 — LlmCartReviewer (no auto-fix yet):**
- Implement `review()` — LLM categorizes items into the four buckets
- Add `send_cart_review_table` to `notify.rb`
- Update `cmd_build_cart` in `main.rb` to call reviewer + send table
- Verify: cart-ready message includes the review table; categories look reasonable

**Step 3 — Auto-fix:**
- Add auto-fix pass to `LlmCartReviewer.review()` — one targeted cart.py call per happy-case item
- Add targeted correction mode to `cart.py` (remove + re-add without clearing full cart)
- Update `auto_corrected` / `auto_fix_failed` sections of review table
- Verify: at least one happy case gets auto-corrected end-to-end

**Step 4 — `/cart-correction`:**
- Add `cmd_cart_correction` handler to `notify.rb`
- LLM parsing of correction text → structured correction
- Preview + confirm flow (same pattern as `/add`)
- Product_map update + `build-cart --force` trigger
- Verify: send a test correction, rebuild fires, new review table arrives

---

**Key files:**
- `cart_builder/cart.py` — extend `items_added` output; add targeted correction mode (remove + re-add without full cart clear)
- `lib/autochef/cart_client.rb` — pass `recipe_qty_description` per item; accept targeted correction payload
- `lib/autochef/llm_cart_reviewer.rb` — new: vision LLM call, categorization, auto-fix orchestration
- `lib/autochef/notify.rb` — `send_cart_review_table`, `cmd_cart_correction`, correction pending state
- `main.rb` — call `LlmCartReviewer.review` after `cmd_build_cart`; handle `/cart-correction` command
- `config.yaml` — add `llm.models.cart_reviewer` (use Claude Sonnet for vision)

---

### 8. LLM Aided Shopping

Before adding each item to the Food Lion cart, the LLM reviews available search results (via screenshot) and picks the best match based on recipe needs and stored preferences. Toggleable from Telegram — on by default.

**Toggle:** On by default. Toggle with Telegram `/shopping-llm on` or `/shopping-llm off`. State persisted in DB. When off, `cart.py` falls back to the existing "add first result" behavior — normal build-cart always works.

**Flow per item (when enabled):**
1. `cart.py` searches for the item (existing behavior)
2. Instead of immediately clicking Add, captures a screenshot of the search results page
3. Screenshot + context (recipe need, qty, unit, matching `PreferenceNote`s) sent to LLM
4. LLM returns: `{action: "add" | "skip", result_index: N, reason: "..."}`
5. `cart.py` adds the selected result, or skips and records the reason
6. Skip/flag reasons collected across all items → included in Telegram cart-ready message

**PreferenceNote model (new AR model, migration 012):**
- `ingredient_pattern` STRING — matched against cart item search term (substring match)
- `note` TEXT — freeform: "always get Organic Valley 2% milk", "store brand OK for butter", "never imitation"
- `created_at`, `updated_at`

**How preferences are collected (naturally, non-disruptive):**
- When the LLM skips an item, the Telegram skip note prompts: "Skipped: shredded cheese — no preference on file. Use `/prefs add 'shredded cheese' 'Kraft Mexican blend 8oz'` to set one."
- Bailey can ignore the hint entirely — the flow still works, LLM just picks best available next time
- `/prefs list`, `/prefs add <pattern> <note>`, `/prefs delete <id>` — Telegram commands

**Tuning:**
- Preferences narrow the LLM's choices for specific items
- For items with no preference, LLM picks based on recipe need and common sense (brand swap OK, fake substitute not OK)
- `seed_product_map.rb --update` still works for fixing search terms; preferences are separate from the product map

**Fallback (LLM can't pick a good option):**
- Item is skipped — not added to cart
- Telegram note: "⚠️ Could not find a good match for [item] — add manually."
- No bad options added; small substitutions OK (brand swap), genuine different product is not OK

**Feasibility notes:**
- Adds 1–3 seconds per item (Playwright screenshot) + LLM call overhead
- Est. API cost: ~$0.01–0.05 per build-cart run at 24 items
- Food Lion search results are fairly consistent but watch for DOM changes
- Toggle off immediately if it breaks; normal cart build is always the fallback

**Key files:**
- `lib/autochef/models/preference_note.rb` — new AR model
- `lib/autochef/database.rb` — migration 012 (`preference_notes` table)
- `lib/autochef/llm_shopping_selector.rb` — new: screenshot → LLM → selection decision per item
- `cart_builder/cart.py` — accept `--llm-shopping` flag; capture search result screenshots; receive LLM decisions
- `lib/autochef/cart_client.rb` — pass toggle state and preference notes to cart.py
- `lib/autochef/notify.rb` — handle skip notes in `send_cart_ready`
- `main.rb` — `/prefs` and `/shopping-llm` Telegram command handlers

---

### 9. Recipe Sleep

Allow Bailey to put a recipe to sleep from the plan approval or swap flow. Sleeping recipes are excluded from the eligible pool until the sleep expires.

**Sleep duration progression:**

| `sleep_count` before this sleep | Duration |
|---|---|
| 0 | 2 weeks |
| 1 | 4 weeks |
| 2 | 16 weeks |
| 3 | 32 weeks |
| 4+ | 52 weeks (cap — recipe always returns within a year) |

Reset: clears `sleep_count` to 0 and `sleep_until` to nil. Available via `/sleeping` command.

**DB changes (new migration 010):**
Add to `recipe_stats`:
- `sleep_until` DATE nullable — date when sleep expires (nil = not sleeping)
- `sleep_count` INTEGER NOT NULL DEFAULT 0

**Eligibility check:**
In `scorer.rb` / `planner.rb`: exclude any `RecipeStat` where `sleep_until IS NOT NULL AND sleep_until > Date.today`.

**Bot flow — plan approval message:**
```
[✅ Keep] [🔁 Swap] [😴 Sleep]
```

**Swap flow** — Sleep is the first option presented before swap candidates:
```
[😴 Sleep this recipe instead] [Swap candidate 1] [Swap candidate 2] ...
```

**After tapping Sleep:**
- Compute duration from `sleep_count`
- Set `sleep_until = Date.today + duration_days`, increment `sleep_count`
- Auto-swap the slept recipe with the next best candidate
- Bot replies: "😴 [Recipe] sleeping for N weeks (returns [date]). Swapped with [replacement]."

**`/sleeping` command:**
```
*Sleeping recipes:*
  • Greek Salmon — wakes up Thu Jul 30 (2 wks, sleep #1)
  [Reset]
```
Reset button clears `sleep_until` and `sleep_count` for that recipe.

**Key files:**
- `lib/autochef/database.rb` — migration 010
- `lib/autochef/models/recipe_stat.rb` — `sleep_duration_weeks` helper + eligibility scope
- `lib/autochef/scorer.rb` — filter sleeping recipes before scoring
- `lib/autochef/notify.rb` — Sleep buttons in plan + swap flow; `/sleeping` handler
- `main.rb` — `cmd_sleeping`; `sleep_recipe`, `reset_sleep` callback handlers

---

### 10. LLM Recipe Suggestions (`/newrecipes`)

Bailey can trigger a new-recipe suggestion round from Telegram at any time, with optional
freeform context to guide the suggestions.

**Usage:**
```
/newrecipes
/newrecipes give me something practical and quick, something asian
/newrecipes I want a comfort food project for the weekend
```

Any text after `/newrecipes` is passed directly to the LLM as a freeform guidance note.
When no note is given, suggestions are based purely on past preferences.

**Context sent to LLM:**
- Recipes with `times_planned >= 2` OR Mealie `rating >= 4` OR positive feedback → "liked" recipes with cuisine/protein/effort tags
- Current recipe pool (to avoid re-suggesting something already in Mealie)
- Last N suggestion feedback entries (so suggestions improve over time)
- The inline guidance note, if provided (takes priority over inferred preferences)

**LLM call:**
- Model: Claude Sonnet (has `web_search` tool)
- Web search: finds real recipe URLs from reputable sources (Serious Eats, NYT Cooking, AllRecipes)
- Fallback: generation from training data, marked `source: generated`
- Output per suggestion: `{name, source_url | null, description, why_it_fits}`

**Telegram flow — one message per suggestion:**
```
*[Recipe Name]*
[2-sentence description]
Source: [URL] — or — Generated by Claude
Why it fits: [rationale]

[✅ Import] [❌ Skip] [💬 Feedback]
```

- **✅ Import**: Mealie import flow (POST create by name → PATCH with tags + metadata → sync equivalent) → "✅ [Recipe] added to Mealie." → then triggers LLM Assisted Recipe Mapping for the new recipe's ingredients
- **❌ Skip**: records skip in DB + log, no comment required
- **💬 Feedback**: bot prompts "What didn't you like?" → records text in DB + log

**Feedback storage — `recipe_suggestion_feedback` table (migration 011):**
- `id`, `recipe_name`, `source_url`, `action` (imported/skipped/feedback), `feedback_text`, `suggested_at`, `acted_at`

**Text export `data/suggestion_feedback.txt`:** append-only log:
```
2026-07-01 | Greek Chicken Bowl | https://... | skipped | "not a fan of bowl meals"
```

**Key files:**
- `lib/autochef/llm_recipe_suggester.rb` — new
- `lib/autochef/models/recipe_suggestion_feedback.rb` — new AR model
- `lib/autochef/database.rb` — migration 011
- `lib/autochef/notify.rb` — `send_recipe_suggestions` + suggestion buttons
- `main.rb` — `cmd_newrecipes`; `/newrecipes` bot command; `import_suggestion`, `skip_suggestion`, `feedback_suggestion` callbacks

---

### 11. Recipe Telegram Commands (`/recipelist`, `/recipe`)

Let Bailey look up the week's meal plan and fetch full recipe details (ingredients + instructions) without leaving Telegram.

---

#### `/recipelist`

Shows all cook days from the current approved week plan with recipe name and planned servings.

```
/recipelist
```

**Response format:**
```
*Week of Monday, June 30*

Sun Jun 29: Greek Salmon with Rice Pilaf — 2 srv
Mon Jun 30: Chicken Thigh Tacos — 4 srv
Wed Jul 2: Sheet Pan Lemon Chicken — 4 srv
Fri Jul 4: Baked Ziti — 4 srv
```

- Shows only cook days (days with assigned recipes); leftover days are omitted
- Reads from the most recently approved `PlanHistory` record
- No Mealie API call needed — all data is in the local DB

---

#### `/recipe`

Fetch full recipe details for a specific planned meal.

**By day (matches cook day in current week plan):**
```
/recipe Sunday
/recipe Sun
/recipe Sunday Dinner
```

**By fuzzy title (matched against current week's recipe names):**
```
/recipe salmon
/recipe greek salad
/recipe chicken tacos
```

**Disambiguation (when fuzzy match finds multiple candidates):**
```
Bot: Did you mean one of these?
[Greek Salmon with Rice Pilaf]  [Miso Salmon Bowl]
```
Inline button tap → sends the recipe.

---

#### Recipe response format

Telegram has a 4096 character limit per message. Long recipes (with many steps) are split across two messages:
- Message 1: Recipe name + servings + full ingredients list (scaled to planned servings)
- Message 2: Instructions

**Example output (Message 1):**
```
*Greek Salmon with Rice Pilaf*
_2 servings — Sunday, June 29_

*Ingredients:*
• 2 salmon fillets (6 oz each)
• 1 cup long-grain white rice
• 2 tbsp olive oil
• 1 lemon, juiced
• 2 cloves garlic, minced
• 1 tsp dried oregano
• Salt and pepper to taste
• 2 cups chicken broth
```

**Example output (Message 2):**
```
*Instructions:*

1. Preheat oven to 400°F.
2. Cook rice in chicken broth per package directions.
3. Mix olive oil, lemon juice, garlic, and oregano.
...
```

**Ingredient scaling:** Plan servings ÷ Mealie recipe default servings × each ingredient quantity. Uses the same scaling logic as `ShoppingListBuilder`.

**Phase 2 enhancement (future backlog):** LLM-formatted version where ingredient quantities are woven into the step-by-step instructions (e.g. "Mix 2 tbsp olive oil, juice of 1 lemon, 2 minced garlic cloves, and 1 tsp dried oregano"). Spec this separately when implementing.

---

#### Scope decisions

- `/recipe` searches **current week's plan only** (not the full Mealie pool)
- Future: `/recipepool <title>` — fuzzy search against all auto-plan tagged recipes in Mealie (separate backlog item)
- Disambiguation uses inline buttons (consistent with existing approve/swap UX)

---

#### Data flow

1. `cmd_recipelist` (or `cmd_recipe`): load latest approved `PlanHistory` from local DB
2. Filter to cook days only
3. For `/recipe` by day: match day abbreviation/name to plan entry (same logic as `find_date_for_day` in `notify.rb`)
4. For `/recipe` by title: fuzzy-match recipe names in the plan using substring/word overlap
5. Fetch full recipe from Mealie: `mealie_client.recipe(recipe_id)`
6. Scale ingredients to plan servings
7. Format and send (split if > ~3500 chars to leave room for Telegram overhead)

---

**Key files:**
- `lib/autochef/notify.rb` — `cmd_recipelist`, `cmd_recipe`, disambiguation button callbacks
- `lib/autochef/mealie_client.rb` — `recipe(id)` already exists; no changes needed
- `main.rb` — register `/recipelist` and `/recipe` in `handle_message`
- `cmd_help` update — add the two new commands to the help text

---

## Infrastructure

### 12. Unraid Docker Display (Xvfb)

**Status:** Must be resolved before Docker deployment on Unraid. `headless=False` in `cart.py` is non-negotiable (Food Lion's bot-detection blocks headless browsers), but Docker on Unraid has no physical display. Xvfb provides a virtual framebuffer so Chrome runs "headed" inside the container.

---

#### What needs to change

**`docker/Dockerfile` — install Xvfb:**
```dockerfile
RUN apt-get update && apt-get install -y \
    xvfb \
    && rm -rf /var/lib/apt/lists/*
```
(Add `xvfb` to the existing `apt-get install` block — don't create a separate RUN layer.)

**`docker/entrypoint.sh` — new file:**
```bash
#!/bin/bash
set -e

# Start Xvfb virtual display on :99
Xvfb :99 -screen 0 1280x1024x24 &
XVFB_PID=$!
export DISPLAY=:99

# Give Xvfb a moment to be ready
sleep 1

# Hand off to the main process
exec "$@"

# Cleanup on exit (Xvfb will also die when the container stops — this is belt-and-suspenders)
kill $XVFB_PID 2>/dev/null || true
```

**`docker/Dockerfile` — set entrypoint:**
```dockerfile
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "main.rb", "serve"]
```

**`docker/docker-compose.yml` — add display env var:**
```yaml
environment:
  DISPLAY: ":99"
```
(Belt-and-suspenders alongside the entrypoint export. Some tools read `DISPLAY` from the environment directly.)

---

#### Local dev — no changes needed

macOS sets `DISPLAY` automatically. `cart.py` runs headed on the local machine without Xvfb. The entrypoint script is only used inside Docker.

---

#### How to verify on Unraid

1. Build and start the container: `docker compose up -d --build`
2. Check Xvfb started: `docker exec mealie-autochef ps aux | grep Xvfb`
3. Run a build-cart: `docker exec mealie-autochef bundle exec ruby main.rb build-cart --force`
4. Expected: Chrome opens (virtually), cart builds, screenshot arrives in Telegram

If Chrome fails to start: check `docker logs mealie-autochef` for "cannot open display" errors. Verify `DISPLAY=:99` is in the container environment with `docker exec mealie-autochef env | grep DISPLAY`.

---

**Key files:**
- `docker/Dockerfile` — add `xvfb` to apt-get block; add `ENTRYPOINT` and `CMD`
- `docker/entrypoint.sh` — new: start Xvfb, export DISPLAY, exec main process
- `docker/docker-compose.yml` — add `DISPLAY: ":99"` to environment

---

### 13. Docker Deployment on Unraid

After stable local operation is confirmed and Xvfb (section 12 above) is in place.

Dockerfile and `docker-compose.yml` already exist in `docker/`. Key considerations:
- `CART_BUILDER_PYTHON` in Docker will point to the venv Python inside the container
- `playwright_state.json` must be volume-mounted (persists across container restarts)
- Mealie URL switches from `http://192.168.1.64:3000` to `http://mealie:9000` on `mealie_net`
- **TODO (test after deploy):** "⚙ Configure week" button URL uses `web.host` (192.168.1.64) — verify the link opens correctly from Telegram once the container is running on Unraid

### 14. Uptime Kuma Push Monitor

Bailey creates a Push monitor in Kuma at `192.168.1.64:3001`, pastes the push URL into `.env` as `UPTIME_KUMA_PUSH_URL`. `main.rb plan` already has a stub to POST to this URL after a successful run.

### 15. MCP Setup

Docker MCP server so Claude Code can manage containers directly. Deferred until Docker deployment is stable.
