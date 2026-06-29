# Improvement — Cart Builder Package Refactor

> **Status:** Partially implemented — Step 2 complete (Python skeleton + `base.py`). Steps 3–6 pending.
>
> **Lifecycle:** Once fully implemented, remove the Migration Order section, fill in actual file
> paths and usage notes, and document how to add a new grocery store provider.

---

## Goal

Restructure `cart_builder/` into a proper Python package that separates provider-specific DOM code
(Food Lion) from the general cart-building workflow. Each layer is independently testable. Adding
support for a second grocery store should require only writing a new provider class — not touching
the workflow, the Ruby integration, or the CLI contract.

---

## Design decisions (fixed — don't revisit without good reason)

| Decision | Rationale |
|---|---|
| Ruby/Python JSON contract is unchanged | `cart.py` still reads stdin, writes stdout. Ruby doesn't need to know about the internal restructure. |
| Coarse provider interface (5 methods) | Easy to implement a new provider. Individual DOM steps are private to the provider. |
| Provider owns the browser session | `Page`, `BrowserContext`, `Browser` are internal to the provider. The workflow never touches Playwright objects directly. |
| `SessionExpiredError` crosses the boundary as an exception | Keeps method signatures clean — `navigate_to_store` either succeeds or raises. |
| Provider-owned slot selection | `select_slot(pref)` is on the provider. Providers that don't have slot pickers return `None`. |
| Previous Purchases is provider-internal | `add_items()` handles PP-first logic internally. |
| No Playwright types in `base.py` | The ABC is library-agnostic — a future provider could use Selenium or httpx. |

---

## Target package structure

```
cart_builder/
├── __init__.py                   ✅ done (Step 2)
├── cart.py                       # CLI entrypoint — Ruby still calls 'python3 cart_builder/cart.py'
├── base.py                       ✅ done (Step 2) — GroceryProvider ABC + CartItem/CartSummary + SessionExpiredError
├── workflow.py                   # CartWorkflow — provider-agnostic orchestration
├── providers/
│   ├── __init__.py               ✅ done (Step 2)
│   ├── food_lion.py              # FoodLionProvider — all Food Lion / Instacart DOM code
│   └── fixture.py                # FixtureProvider — static data, no browser, for tests
├── tests/
│   ├── __init__.py               ✅ done (Step 2)
│   ├── test_workflow.py          # tests CartWorkflow against FixtureProvider — no browser
│   ├── test_food_lion.py         # @pytest.mark.live — requires real Chrome + auth state
│   └── fixtures/
│       ├── sample_input.json     ✅ done (Step 2)
│       └── sample_summary.json   ✅ done (Step 2)
├── probe_pp.py                   ✅ already exists
└── README.md                     # package docs: provider contract, how to add a provider, how to run tests
```

---

## `base.py` — core types and provider contract (already implemented)

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
    previous_purchases_stats: Optional[dict]

class SessionExpiredError(Exception):
    def __init__(self, reason: str):
        self.reason = reason  # "kasada_challenge" | "login_required"
        super().__init__(reason)

class GroceryProvider(ABC):
    @abstractmethod
    def navigate_to_store(self, store_name: str) -> None: ...
    @abstractmethod
    def clear_cart(self) -> int: ...
    @abstractmethod
    def select_slot(self, pickup_window_pref: str) -> Optional[str]: ...
    @abstractmethod
    def add_items(self, items: list[CartItem]) -> tuple[list[CartItem], list[str]]: ...
    @abstractmethod
    def capture_summary(self, run_key: str) -> CartSummary: ...
```

---

## `workflow.py` — CartWorkflow (to implement in Step 4)

Provider-agnostic. Never imports Playwright. Handles: calling provider methods in order,
catching `SessionExpiredError` → `session_expired` output, spending cap check, building final
JSON output (same structure as today's `make_output()`).

```python
class CartWorkflow:
    def __init__(self, provider: GroceryProvider):
        self.provider = provider

    def run(self, payload: dict) -> dict:
        store_name   = payload.get("store_name", "")
        pickup_pref  = payload.get("pickup_window_pref", "")
        spending_cap = payload.get("spending_cap_usd")
        dry_run      = payload.get("dry_run", True)
        run_key      = payload.get("run_key", "unknown")
        raw_items    = payload.get("items", [])

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

## `providers/food_lion.py` — FoodLionProvider (to implement in Step 3)

All existing `cart.py` code moves here as class methods. Selector constants become class-level
attributes.

| Existing function(s) | FoodLionProvider method |
|---|---|
| `navigate_to_store()` + `detect_session_state()` + `dismiss_modals()` | `navigate_to_store()` — raises `SessionExpiredError` on bad session |
| `clear_cart()` | `clear_cart()` |
| `set_pickup_mode()` + `select_pickup_slot()` | `select_slot()` |
| `add_from_previous_purchases()` + `add_item_to_cart()` loop | `add_items()` — PP pass first, search fallback |
| `capture_cart_summary()` + screenshot | `capture_summary()` |

Provider opens and closes its own `sync_playwright` context in `__init__` / `__del__` or via a
context manager (`with FoodLionProvider(...) as p:`).

---

## `providers/fixture.py` — FixtureProvider (to implement in Step 5)

No browser. Returns pre-canned data. Used exclusively by `test_workflow.py`.

```python
class FixtureProvider(GroceryProvider):
    def navigate_to_store(self, store_name: str) -> None: pass
    def clear_cart(self) -> int: return 3
    def select_slot(self, pref: str) -> Optional[str]: return "Thu 5:00–6:00 PM"
    def add_items(self, items):
        added   = [i for i in items if i.search_term != "FLAGGED"]
        flagged = [i.search_term for i in items if i.search_term == "FLAGGED"]
        return added, flagged
    def capture_summary(self, run_key: str) -> CartSummary:
        return CartSummary(
            total=89.42, item_count=5, pickup_slot="Thu 5:00–6:00 PM",
            flagged_items=[], screenshot_path=None,
            previous_purchases_stats={"available": 12, "matched": 3, "search_adds": 2},
        )
```

A `SessionExpiredFixtureProvider` variant raises `SessionExpiredError("kasada_challenge")` from
`navigate_to_store` for testing the `session_expired` output path.

---

## `cart.py` — CLI entrypoint after refactor (Step 4)

```python
PROVIDER_MAP = {
    "food_lion": FoodLionProvider,
    # "kroger": KrogerProvider,  # future
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--login",   action="store_true")
    parser.add_argument("--fixture", metavar="FILE")
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

---

## Test strategy

| Test file | What it covers | Browser needed? |
|---|---|---|
| `cart_builder/tests/test_workflow.py` | CartWorkflow routing, session_expired, spending_cap abort, flagged items | No — uses FixtureProvider |
| `cart_builder/tests/test_workflow.py` | `SessionExpiredFixtureProvider` → confirms `session_expired` output shape | No |
| `cart_builder/tests/test_food_lion.py` | `@pytest.mark.live` — FoodLionProvider against live site | Yes — run manually |

Run after any change to `workflow.py` or `base.py`:
```bash
source .venv/bin/activate && pytest cart_builder/tests/test_workflow.py -v
```

---

## Migration order

**✅ Step 2 — Python package skeleton (seventeenth session):**
- `cart_builder/__init__.py`, `base.py`, `providers/__init__.py`, `tests/__init__.py`, fixture JSON
- No behavior change

**Step 1 — Ruby side (independent, can be done alongside Step 3):**
- See [Application Orchestrator Refactor](improvement_orchestrator_refactor.md) Section 3 for
  `CartResolver` and `CartConsolidator` extraction

**Step 3 — Extract FoodLionProvider:**
- Create `providers/food_lion.py`; move all selector constants + the five workflow functions
- Update `cart.py` to import and use `FoodLionProvider` — no behavior change
- Verify: `bundle exec ruby main.rb build-cart --force` still works

**Step 4 — Extract CartWorkflow:**
- Create `workflow.py`; wire `FoodLionProvider` + `CartWorkflow` in `cart.py`
- Verify: `bundle exec ruby main.rb build-cart --force` still works

**Step 5 — FixtureProvider + tests + `--fixture` flag:**
- Create `providers/fixture.py` with `FixtureProvider` and `SessionExpiredFixtureProvider`
- Write `tests/test_workflow.py`; add `--fixture` arg
- `pytest cart_builder/tests/test_workflow.py` must pass with no browser

**Step 6 — Documentation:**
- Write `cart_builder/README.md` (provider contract, how to add a provider, how to run tests,
  Ruby/Python JSON contract)
- Update `TESTING_HANDOFF.md`

---

## Key files

| File | Status |
|---|---|
| `cart_builder/__init__.py` | ✅ done |
| `cart_builder/base.py` | ✅ done |
| `cart_builder/workflow.py` | pending (Step 4) |
| `cart_builder/providers/__init__.py` | ✅ done |
| `cart_builder/providers/food_lion.py` | pending (Step 3) |
| `cart_builder/providers/fixture.py` | pending (Step 5) |
| `cart_builder/tests/` | skeleton done; `test_workflow.py` pending (Step 5) |
| `cart_builder/cart.py` | pending slim-down (Step 4) |
| `cart_builder/README.md` | pending (Step 6) |
| `lib/autochef/cart_resolver.rb` | pending (Orchestrator Refactor Section 3) |
| `lib/autochef/cart_consolidator.rb` | pending (Orchestrator Refactor Section 3) |
