"""
cart.py — Playwright Food Lion To Go (pickup) cart builder.

WHY THIS IS PYTHON, NOT RUBY:
This project is otherwise pure Ruby (ActiveRecord for the DB, plain Ruby
for scoring/planning/notify/etc). This single file is the one deliberate
exception. Reasons, in order of weight:

  1. Playwright's Python bindings are the official, first-party, most
     battle-tested ones. Ruby's option (`playwright-ruby-client`) is a
     community wrapper around the same underlying driver, with a much
     smaller user base. The cart builder is already the most fragile,
     highest-maintenance part of this whole system (see MEMORY.md) —
     it's the wrong place to add a second layer of "less proven library"
     risk on top of "automating a site that wasn't built to be automated."
  2. This script runs as an isolated, cron-triggered batch process anyway
     (see architecture diagram in MEALIE_AUTOMATION_PLAN.md section 3) —
     it was never going to be imported in-process by the rest of the app,
     so a language boundary here costs nothing architecturally.

CONTRACT WITH THE RUBY SIDE (lib/autochef/cart_client.rb):
  - Ruby invokes this script as a subprocess (no daemon, no socket).
  - Input: a single JSON blob on stdin — the approved "Next Order" item
    list plus run context. See INPUT_SCHEMA below.
  - Output: a single JSON object on stdout (and ONLY that JSON — no other
    prints to stdout). See OUTPUT_SCHEMA below. Logs/diagnostics go to
    stderr, never stdout, so Ruby's stdout capture stays parse-able.
  - Exit code 0 = ran to completion (cart built OR explicitly aborted by a
    safety rule — check `status` in the output for which). Nonzero exit =
    unexpected crash; Ruby treats this as a hard failure, not a flagged cart.
  - Screenshots are written to disk (data/cart_screenshots/<run_key>.png)
    and only their PATH is included in the JSON output — not embedded as
    base64 — to keep the stdout payload small and the contract simple.

INPUT_SCHEMA (stdin, JSON):
  {
    "run_key": str,
    "store_name": str,
    "pickup_window_pref": str,           # e.g. "Sun 10:00-12:00"
    "spending_cap_usd": float,
    "cart_deviation_alert_pct": float,
    "dry_run": bool,
    "items": [
      {"search_term": str, "default_qty": int, "pack_unit": str | null}
    ]
  }

OUTPUT_SCHEMA (stdout, JSON):
  {
    "status": "cart_built" | "aborted" | "session_expired",
    "abort_reason": str | null,          # set when status == "aborted"
    "est_total": float | null,
    "cart_total": float | null,
    "pickup_slot": str | null,
    "flagged_items": [str],              # out-of-stock / unmapped, never silently substituted
    "screenshot_path": str | null,
    "cart_url": str | null,
    "previous_purchases_stats": {        # null when previous purchases page not accessible
      "available": int,                  # items visible on Previous Purchases page
      "matched": int,                    # items added directly from Previous Purchases
      "search_adds": int                 # items that fell back to search
    } | null
  }

SELECTOR MAINTENANCE:
  Food Lion To Go is powered by Instacart's white-label storefront. Selectors
  are documented inline throughout this file. When the UI changes:
  1. Run: playwright codegen https://www.foodlion.com/shop
  2. Interact with the element that broke.
  3. Copy the selector from Codegen's output and update the relevant constant.

  Each selector list is tried in order; first match wins. This makes the script
  resilient to minor UI refactors without needing to rewrite logic.

FIRST-TIME SETUP:
  Run: python3 cart_builder/cart.py --login
  This opens a visible browser, waits for you to log in to Food Lion To Go,
  then saves the session to data/playwright_state.json for all future runs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Optional

from playwright.sync_api import (
    Browser,
    BrowserContext,
    Page,
    sync_playwright,
    TimeoutError as PlaywrightTimeout,
)


# ─── Constants ────────────────────────────────────────────────────────────────

# Canonical entry point for Food Lion's Instacart-powered storefront.
# If Food Lion redirects to a different path, update this and AUTH_EXPECTED_DOMAIN.
FOODLION_TOGO_URL = "https://www.foodlion.com/shop"

# Direct URL to Food Lion's Past Purchases page.
# Confirmed URL from live Food Lion account (2026-06-28).
PREV_PURCHASES_URL = "https://www.foodlion.com/past-purchases"

# Minimum word-overlap fraction to consider a previous purchase a match.
# 0.6 means 60% of significant words in the search term must appear in the
# product name. Two-word terms need both words; three-word terms need two.
PREV_MATCH_THRESHOLD = 0.6

# Words that carry no useful signal for matching (stripped before scoring).
PREV_STOP_WORDS = frozenset({
    "a", "an", "the", "of", "with", "and", "or", "for", "in", "to",
    "lb", "lbs", "oz", "pkg", "pack", "count", "ct", "fl", "g", "kg", "ml",
})

# The domain Playwright should land on after login — used to detect redirects.
# Food Lion To Go may redirect to instacart.com or stay on foodlion.com.
AUTH_EXPECTED_DOMAIN = "foodlion.com"

AUTH_STATE_PATH = Path("data/playwright_state.json")
SCREENSHOT_DIR = Path("data/cart_screenshots")

# Human-like pacing delays (milliseconds). These reduce bot-detection risk on
# a site that wasn't built to be automated — see spec section 9.7.
STEP_DELAY_MS = 600          # between distinct UI actions
SEARCH_WAIT_MS = 1500        # after typing a search term before checking results
CART_SETTLE_MS = 1000        # after adding an item before moving to the next
PAGE_LOAD_TIMEOUT_MS = 30000  # max wait for any page/selector to appear
SLOT_PICKER_TIMEOUT_MS = 20000


# ─── Selectors ────────────────────────────────────────────────────────────────
# Each is a list of candidates tried in order. Update the first element when
# the UI changes; keep the rest as fallbacks for partial-rollout periods.

# Search bar input
SEL_SEARCH = [
    '[data-testid="search-bar-input"]',
    '[data-testid="search-input"]',
    'input[aria-label*="Search" i]',
    'input[placeholder*="Search" i]',
    'input[type="search"]',
]

# "Pickup" mode toggle/button in the delivery-vs-pickup selector
SEL_PICKUP_MODE = [
    '[data-testid="pickup-tab"]',
    '[data-testid*="pickup"]',
    'button:has-text("Pickup")',
    '[role="tab"]:has-text("Pickup")',
    'label:has-text("Pickup")',
]

# Button that opens the pickup time-slot picker
SEL_SCHEDULE_BTN = [
    '[data-testid="schedule-order-button"]',
    '[data-testid*="schedule"]',
    '[data-testid*="time-slot-selector"]',
    'button:has-text("Schedule")',
    'button:has-text("Choose a time")',
    'button:has-text("Pick a time")',
    'button:has-text("Select time")',
]

# Individual time-slot option inside the slot picker
SEL_TIME_SLOT = [
    '[data-testid*="time-slot"]',
    '[data-testid*="delivery-window"]',
    '[role="radio"]:has-text("am")',
    '[role="radio"]:has-text("pm")',
    'label:has-text("am")',
    'label:has-text("pm")',
    '.time-slot',
    '.delivery-window',
]

# "Confirm" / "Done" button inside the slot picker
SEL_SLOT_CONFIRM = [
    '[data-testid="slot-confirm-button"]',
    'button:has-text("Confirm")',
    'button:has-text("Done")',
    'button:has-text("Save")',
    'button[type="submit"]',
]

# "Add" / "+ Add" button on a product card in search results
SEL_ADD_BTN = [
    '[data-testid="add-to-cart-button"]',
    '[data-testid*="add-item"]',
    '[data-testid*="add-to-cart"]',
    'button[aria-label*="Add to cart" i]',
    'button[aria-label*="Add to Cart" i]',
    'button:has-text("Add to Cart")',
    'button:has-text("+ Add to Cart")',
    'button:has-text("Add to cart")',
]

# Cart subtotal / total display
SEL_CART_TOTAL = [
    '[data-testid="cart-subtotal"]',
    '[data-testid="cart-total"]',
    '[data-testid*="subtotal"]',
    '[aria-label*="subtotal" i]',
    '[aria-label*="total" i]',
    '.cart-subtotal',
    '.order-total',
]

# Out-of-stock indicator on a product card
SEL_OUT_OF_STOCK = [
    '[data-testid*="out-of-stock"]',
    'text="Out of stock"',
    'text="Unavailable"',
    '.out-of-stock',
]

# The cart icon / cart sidebar open button
SEL_CART_BTN = [
    '[data-testid="cart-icon"]',
    '[data-testid*="cart-button"]',
    '[aria-label*="cart" i]',
    'a[href*="cart"]',
]

# Remove/delete button on an individual cart item — used by clear_cart()
SEL_CART_ITEM_REMOVE = [
    '[data-testid="trash-button"]',
    '[data-testid*="remove-item"]',
    '[data-testid*="delete-item"]',
    '[data-testid*="item-remove"]',
    'button[aria-label*="Remove" i]',
    'button[aria-label*="Delete" i]',
]

# "OK" / confirm button in the "Remove this item from your cart?" dialog
SEL_CART_ITEM_REMOVE_CONFIRM = [
    'button:has-text("OK")',
    'button:has-text("Yes")',
    'button:has-text("Confirm")',
]

# ── Login automation selectors ─────────────────────────────────────────────────
# Used by run_login() when FOODLION_USERNAME/FOODLION_PASSWORD are set.

SEL_SIGNIN_LINK = [
    'a:has-text("Sign In")',
    'button:has-text("Sign In")',
    '[data-testid*="sign-in"]',
    '[aria-label*="Sign In" i]',
    'a[href*="login"]',
    'a[href*="sign-in"]',
]

SEL_EMAIL_INPUT = [
    'input[type="email"]',
    'input[autocomplete="email"]',
    'input[name="email"]',
    'input[id*="email" i]',
    'input[placeholder*="email" i]',
]

SEL_PASSWORD_INPUT = [
    'input[type="password"]',
    'input[autocomplete="current-password"]',
    'input[name="password"]',
    'input[id*="password" i]',
]

# "Continue" / "Next" button after entering email in a two-step login flow
SEL_LOGIN_CONTINUE = [
    'button:has-text("Continue")',
    'button:has-text("Next")',
]

SEL_LOGIN_SUBMIT = [
    'button[type="submit"]',
    'button:has-text("Sign In")',
    'button:has-text("Log In")',
    'button:has-text("Login")',
]

# Navigation link to Food Lion's Past Purchases page (top nav bar).
# Confirmed present in Food Lion nav as "Past Purchases" (2026-06-28).
SEL_MY_ITEMS_LINK = [
    '[data-testid*="past-purchases"]',
    'a[href*="past-purchases"]',
    'a:has-text("Past Purchases")',
    'nav a:has-text("Past")',
    '[aria-label*="Past Purchases" i]',
]

# Food Lion uses a direct /past-purchases page, not a tabbed "My Items" layout.
# No tab click is needed — kept as empty list so try_click is a harmless no-op.
SEL_PREV_PURCHASES_TAB: list[str] = []

# Product card containers on the Previous Purchases page.
# Food Lion's Past Purchases page uses the PDL (Peapod Digital Labs) component
# library — no data-testid attributes. Each li.product-grid-cell is one product.
# 5 product groups (.pdl-carousel_item each containing a ul.product-list-quint)
# are visible on page load; all 5 × ~13 = 66 li.product-grid-cell cards are
# in the DOM immediately without requiring carousel scroll.
SEL_PREV_PRODUCT_CARD = [
    'li.product-grid-cell',
]

# Product name element within a Previous Purchases card.
# .product-tile_detail-title is a <button> containing the full product name.
# .product-grid-cell_name-text is an <a> anchor with the same name (fallback).
SEL_PREV_PRODUCT_NAME = [
    '[class*="product-tile_detail-title"]',
    '[class*="product-grid-cell_name-text"]',
]


# ─── Helpers ──────────────────────────────────────────────────────────────────

def log(*args) -> None:
    """Write to stderr. stdout is reserved exclusively for the JSON output."""
    print(*args, file=sys.stderr)


def try_click(page: Page, selectors: list[str], timeout: int = PAGE_LOAD_TIMEOUT_MS) -> bool:
    """Try each selector in order, click the first one found. Returns True on success."""
    for sel in selectors:
        try:
            locator = page.locator(sel).first
            locator.wait_for(state="visible", timeout=timeout // len(selectors))
            locator.click()
            return True
        except PlaywrightTimeout:
            continue
        except Exception as e:
            log(f"  click attempt failed ({sel}): {e}")
            continue
    return False


def try_fill(page: Page, selectors: list[str], value: str, timeout: int = PAGE_LOAD_TIMEOUT_MS) -> bool:
    """Try each selector, fill the first found input. Returns True on success."""
    for sel in selectors:
        try:
            locator = page.locator(sel).first
            locator.wait_for(state="visible", timeout=timeout // len(selectors))
            locator.clear()
            locator.fill(value)
            return True
        except PlaywrightTimeout:
            continue
        except Exception as e:
            log(f"  fill attempt failed ({sel}): {e}")
            continue
    return False


def try_text(page: Page, selectors: list[str], timeout: int = PAGE_LOAD_TIMEOUT_MS) -> Optional[str]:
    """Return the inner_text of the first selector found, or None."""
    for sel in selectors:
        try:
            locator = page.locator(sel).first
            locator.wait_for(state="visible", timeout=timeout // len(selectors))
            return locator.inner_text()
        except PlaywrightTimeout:
            continue
        except Exception:
            continue
    return None


def pace(ms: int = STEP_DELAY_MS) -> None:
    """Human-like pause between actions."""
    time.sleep(ms / 1000)


def parse_price(text: Optional[str]) -> Optional[float]:
    """Extract a dollar amount from a string like '$42.57' or 'Subtotal: $42.57'."""
    if not text:
        return None
    match = re.search(r"\$?([\d,]+\.\d{2})", text.replace(",", ""))
    return float(match.group(1)) if match else None


def parse_pickup_window(window_pref: str):
    """
    Parse config pickup_window_pref like 'Sun 10:00-12:00' into
    (day_abbr, start_hour, end_hour). Returns None if unparseable.
    """
    match = re.match(
        r"(\w+)\s+(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})",
        window_pref.strip()
    )
    if not match:
        return None
    day = match.group(1)[:3].capitalize()
    start_h = int(match.group(2))
    end_h = int(match.group(4))
    return day, start_h, end_h


def make_output(
    status: str,
    abort_reason: Optional[str] = None,
    est_total: Optional[float] = None,
    cart_total: Optional[float] = None,
    pickup_slot: Optional[str] = None,
    flagged_items: Optional[list[str]] = None,
    screenshot_path: Optional[str] = None,
    cart_url: Optional[str] = None,
    previous_purchases_stats: Optional[dict] = None,
) -> dict:
    return {
        "status": status,
        "abort_reason": abort_reason,
        "est_total": est_total,
        "cart_total": cart_total,
        "pickup_slot": pickup_slot,
        "flagged_items": flagged_items or [],
        "screenshot_path": screenshot_path,
        "cart_url": cart_url,
        "previous_purchases_stats": previous_purchases_stats,
    }


# ─── Login mode ───────────────────────────────────────────────────────────────

def run_login() -> int:
    """
    Log in to Food Lion and save the session to AUTH_STATE_PATH.

    When FOODLION_USERNAME and FOODLION_PASSWORD are set in the environment:
      - Navigates automatically, solves any Kasada challenge via CapSolver,
        fills credentials, then pauses for 2FA (enter code + press Enter).

    When credentials are absent: falls back to fully manual mode — browser
    opens, you do everything, press Enter when done.
    """
    username = os.environ.get("FOODLION_USERNAME", "")
    password = os.environ.get("FOODLION_PASSWORD", "")

    AUTH_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=False,
            channel="chrome",
            args=["--disable-blink-features=AutomationControlled"],
        )
        context = browser.new_context(viewport={"width": 1280, "height": 800})
        context.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        page = context.new_page()

        if not username or not password:
            log("=== Food Lion manual login (no credentials in env) ===")
            log(f"Opening {FOODLION_TOGO_URL} — log in, then press Enter here.")
            page.goto(FOODLION_TOGO_URL)
            try:
                input()
            except EOFError:
                pass
        else:
            log("=== Food Lion automated login ===")
            log(f"  credentials: {username}")

            # 1. Navigate to store
            log(f"Navigating to {FOODLION_TOGO_URL}...")
            page.goto(FOODLION_TOGO_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
            pace(2000)

            # 2. Solve Kasada if it fires on the initial load.
            # Kasada fires async (2-5s after networkidle) — wait for search bar
            # to confirm the page is actually accessible before checking session state.
            search_visible = False
            try:
                page.locator(SEL_SEARCH[0]).wait_for(state="visible", timeout=5000)
                search_visible = True
            except PlaywrightTimeout:
                pass
            if not search_visible:
                log("Search bar not visible after load — Kasada may have fired, checking...")
            state = detect_session_state(page)
            if state == "kasada_challenge":
                log("Kasada on initial load — calling CapSolver...")
                solve_kasada_challenge(page)

            # 3. Click Sign In in the nav
            log("Clicking Sign In...")
            if not try_click(page, SEL_SIGNIN_LINK, timeout=10000):
                log("  Could not find Sign In link — may already be on login page")
            pace(1500)

            # 4. Solve Kasada if it fires after clicking Sign In
            if detect_session_state(page) == "kasada_challenge":
                log("Kasada on login page — calling CapSolver...")
                solve_kasada_challenge(page)

            # 5. Fill email
            log("Filling email...")
            if try_fill(page, SEL_EMAIL_INPUT, username, timeout=10000):
                pace(500)
                # Some Food Lion flows: email first → Continue → password
                if try_click(page, SEL_LOGIN_CONTINUE, timeout=3000):
                    log("  Two-step flow: clicked Continue")
                    pace(1500)
                    if detect_session_state(page) == "kasada_challenge":
                        log("  Kasada after email step — calling CapSolver...")
                        solve_kasada_challenge(page)
            else:
                log("  Email input not found — continuing")

            # 6. Fill password
            log("Filling password...")
            if not try_fill(page, SEL_PASSWORD_INPUT, password, timeout=8000):
                log("  Password input not found — continuing")
            pace(500)

            # 7. Submit
            log("Submitting credentials...")
            try_click(page, SEL_LOGIN_SUBMIT, timeout=5000)
            pace(3000)

            # 8. Solve Kasada if it fires after credential submission
            if detect_session_state(page) == "kasada_challenge":
                log("Kasada after credential submit — calling CapSolver...")
                solve_kasada_challenge(page)

            # 9. Wait for 2FA
            log("")
            log("=== 2FA prompt ===")
            log("Enter the code sent to your device, then press Enter here.")
            try:
                input()
            except EOFError:
                pass
            pace(2000)

        context.storage_state(path=str(AUTH_STATE_PATH))
        log(f"Session saved to {AUTH_STATE_PATH}")
        browser.close()

    return 0


# ─── Cart-building flow ────────────────────────────────────────────────────────

def setup_context(playwright, headless: bool = True) -> tuple[Browser, BrowserContext]:
    """Launch browser and create context, loading saved auth state if available."""
    browser = playwright.chromium.launch(
        headless=headless,
        channel="chrome",
        args=["--disable-blink-features=AutomationControlled"],
    )

    state_path = str(AUTH_STATE_PATH) if AUTH_STATE_PATH.exists() else None
    if not state_path:
        log("WARNING: No auth state found at data/playwright_state.json.")
        log("         Run: python3 cart_builder/cart.py --login")
        log("         to set up your Food Lion session before building a cart.")

    context = browser.new_context(
        storage_state=state_path,
        viewport={"width": 1280, "height": 800},
    )
    context.add_init_script(
        "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
    )
    return browser, context


def clear_cart(page: Page) -> int:
    """
    Remove all existing items from the Food Lion cart before a fresh build.
    Re-runs are always safe: the cart is cleared then rebuilt from scratch.
    Items added via AutoChef's /add command are in the Mealie shopping list
    and will be re-added by the normal build flow — they are not lost.
    Returns the number of items removed.
    """
    log("Clearing existing cart items...")
    try_click(page, SEL_CART_BTN, timeout=8000)
    pace(1500)

    removed = 0
    for _ in range(60):  # safety cap
        found = False
        for sel in SEL_CART_ITEM_REMOVE:
            els = page.locator(sel)
            if els.count() > 0:
                try:
                    els.first.click()
                    pace(600)
                    # Food Lion shows "Remove this item from your cart? [OK] [Cancel]"
                    try_click(page, SEL_CART_ITEM_REMOVE_CONFIRM, timeout=2000)
                    pace(600)
                    removed += 1
                    found = True
                    break
                except Exception:
                    continue
        if not found:
            break

    log(f"  Cleared {removed} item(s) from cart.")
    # Return to the store page for the normal add flow
    page.goto(FOODLION_TOGO_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
    pace(1500)
    dismiss_modals(page)
    return removed


def dismiss_modals(page: Page) -> None:
    """
    Dismiss known Food Lion interstitial modals that block automation.
    Tries backdrop click (top-left corner) then JS click by exact text.
    """
    pace(1500)  # let modal render

    # Click the backdrop — top-left corner is outside any centered modal
    try:
        page.mouse.click(10, 10)
        pace(500)
        log("  Clicked backdrop to dismiss modal.")
    except Exception:
        pass

    # JS fallback: find "Continue Shopping" by exact text, no visibility check
    clicked = page.evaluate("""
        () => {
            const all = Array.from(document.querySelectorAll('a, button, span'));
            const target = all.find(el => el.textContent.trim() === 'Continue Shopping');
            if (target) { target.click(); return true; }
            return false;
        }
    """)
    if clicked:
        log("  Dismissed modal via JS (Continue Shopping).")
        pace(500)


def navigate_to_store(page: Page, store_name: str) -> bool:
    """
    Navigate to Food Lion To Go and confirm we're on the right store.
    Returns True if on the correct store page, False otherwise.
    """
    log(f"Navigating to {FOODLION_TOGO_URL}")
    page.goto(FOODLION_TOGO_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
    pace(1500)

    # Wait for the page to settle — Food Lion To Go is a heavily JS-driven SPA.
    # We look for any of the store's characteristic elements before proceeding.
    log("Waiting for store page to load...")
    try:
        page.wait_for_load_state("networkidle", timeout=PAGE_LOAD_TIMEOUT_MS)
    except PlaywrightTimeout:
        log("  networkidle timed out — proceeding anyway (SPA may still be loading)")

    page_title = page.title()
    page_url = page.url
    log(f"  Landed on: {page_url} | title: {page_title}")

    # Dismiss any interstitial modals before proceeding.
    dismiss_modals(page)

    # If we're on a generic landing page rather than a storefront, look for
    # "Shop" or "Start shopping" links and click through.
    if "shop" not in page_url.lower() and "store" not in page_url.lower():
        shop_clicked = try_click(page, [
            'a[href*="shop"]',
            'a:has-text("Shop")',
            'button:has-text("Start shopping")',
            'a:has-text("Shop now")',
        ], timeout=8000)
        if shop_clicked:
            pace(2000)
            log(f"  Navigated to: {page.url}")

    return True


def detect_session_state(page: Page) -> str:
    """
    Called immediately after navigate_to_store() to catch auth failures early.
    Returns "kasada_challenge", "login_required", or "valid".

    Kasada challenge: Food Lion's bot-detection page loaded instead of the store.
    Login required: session cookie expired and Food Lion redirected to the sign-in page.
    Both cases require running: python3 cart_builder/cart.py --login
    """
    url = page.url.lower()

    # Login redirect — session cookie gone, Food Lion sent us to a sign-in page.
    if any(kw in url for kw in ("login", "signin", "sign-in", "/account")):
        log(f"  Session check: login redirect detected ({page.url})")
        return "login_required"

    # Kasada challenge — bot-detection page loaded at the original URL.
    # data-kpsdk-v is the Kasada SDK version attribute injected on challenge pages.
    try:
        if page.locator('[data-kpsdk-v], #kp-captcha').count() > 0:
            log("  Session check: Kasada challenge element detected")
            return "kasada_challenge"
    except Exception:
        pass

    title = page.title().lower()
    if any(kw in title for kw in ("just a moment", "please wait", "checking your browser", "enable javascript", "verification required")):
        log(f"  Session check: challenge-like title: {page.title()!r}")
        return "kasada_challenge"

    # Kasada "Verification Required" page — different from the slider; shows
    # image/audio icons + RETRY button. Detected by page body text since the
    # title and DOM attributes don't expose any Kasada-specific identifiers.
    try:
        body = page.locator("body").inner_text(timeout=2000).lower()
        if "verification required" in body and "unusual activity" in body:
            log("  Session check: Kasada 'Verification Required' page detected")
            return "kasada_challenge"
    except Exception:
        pass

    # Sign-in button visible in the main viewport (not just a nav item).
    # Indicates session dropped without a URL redirect.
    try:
        for sel in ('button:has-text("Sign In")', '[data-testid*="sign-in-button"]'):
            loc = page.locator(sel).first
            if loc.count() > 0 and loc.is_visible():
                log(f"  Session check: sign-in button visible ({sel})")
                return "login_required"
    except Exception:
        pass

    log("  Session check: valid")
    return "valid"


def solve_kasada_challenge(page: Page) -> bool:
    """
    Attempt to auto-solve a Kasada bot-detection challenge via CapSolver.
    Returns True if the page is past the challenge after solving, False otherwise.

    Only fires when CAPSOLVER_API_KEY is set in the environment. On any failure
    (API error, wrong solution shape, challenge still present after injection)
    returns False so the caller can fall back to the Option 1 Telegram alert.

    The exact solution keys returned by CapSolver for AntiKasadaTask are logged
    on first use so the injection logic can be refined if needed.
    """
    api_key = os.environ.get("CAPSOLVER_API_KEY", "")
    if not api_key:
        return False

    try:
        import capsolver as _capsolver
    except ImportError:
        log("  CapSolver: package not installed — skipping (run: pip install capsolver)")
        return False

    _capsolver.api_key = api_key
    try:
        log("  CapSolver: submitting AntiKasadaTask...")
        solution = _capsolver.solve({
            "type": "AntiKasadaTask",
            "pageURL": page.url,
        })
        log(f"  CapSolver: solution keys → {list(solution.keys()) if isinstance(solution, dict) else type(solution)}")

        if isinstance(solution, dict):
            # Token injection — Kasada checks window.__kpsdk_answer on page load.
            # Field name varies by CapSolver version; try common candidates.
            token = (
                solution.get("token")
                or solution.get("ct")
                or solution.get("kpsdk_ct")
                or solution.get("kpsdk_answer")
                or ""
            )
            if token:
                log(f"  CapSolver: injecting token ({len(str(token))} chars)")
                page.evaluate(f"window.__kpsdk_answer = {json.dumps(str(token))}")

            # Some CapSolver solutions also return cookies to inject directly
            raw_cookies = solution.get("cookies")
            if raw_cookies:
                if isinstance(raw_cookies, list):
                    page.context.add_cookies(raw_cookies)
                    log(f"  CapSolver: injected {len(raw_cookies)} cookie(s)")

        page.reload(wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
        pace(2000)

        if detect_session_state(page) == "valid":
            log("  CapSolver: challenge cleared successfully")
            return True

        log("  CapSolver: page still shows challenge after injection")
        return False

    except Exception as exc:
        log(f"  CapSolver: solve failed — {exc}")
        return False


def set_pickup_mode(page: Page) -> bool:
    """
    Ensure the order mode is set to Pickup (not Delivery).
    Returns True if pickup mode was confirmed or set successfully.
    """
    log("Setting fulfillment mode to Pickup...")

    # Check if there's already a pickup indicator visible
    pickup_active = page.locator(
        '[data-testid*="pickup"][aria-selected="true"], '
        '[role="tab"]:has-text("Pickup")[aria-selected="true"]'
    ).count()

    if pickup_active > 0:
        log("  Pickup mode already active.")
        return True

    clicked = try_click(page, SEL_PICKUP_MODE, timeout=10000)
    if clicked:
        pace()
        log("  Pickup mode selected.")
        return True

    log("  Could not find pickup toggle — proceeding (may already be in pickup mode).")
    return True  # Non-fatal: site may default to pickup


def select_pickup_slot(page: Page, pickup_window_pref: str) -> Optional[str]:
    """
    Open the slot picker and select a slot within the preferred window.
    If no slot matches the preference, picks the first available and flags it.
    Returns the selected slot label string, or None if selection failed.
    """
    log(f"Selecting pickup slot (preference: {pickup_window_pref})...")

    # Open the slot picker
    opened = try_click(page, SEL_SCHEDULE_BTN, timeout=12000)
    if not opened:
        log("  Could not find slot picker button — slot selection skipped.")
        return None
    pace(1500)

    # Parse the preference window
    parsed = parse_pickup_window(pickup_window_pref)

    # Collect all visible time slot options
    slot_els = []
    for sel in SEL_TIME_SLOT:
        els = page.locator(sel)
        count = els.count()
        if count > 0:
            slot_els = [els.nth(i) for i in range(count)]
            break

    if not slot_els:
        log("  No time slot elements found.")
        return None

    log(f"  Found {len(slot_els)} slot option(s).")

    selected_slot: Optional[str] = None
    best_el = None

    if parsed:
        pref_day, pref_start_h, pref_end_h = parsed
        # Try to find a slot matching the preferred day + time window
        for el in slot_els:
            try:
                label = el.inner_text()
                if (
                    pref_day.lower() in label.lower()
                    and any(
                        str(h) in label
                        for h in range(pref_start_h, pref_end_h + 1)
                    )
                ):
                    best_el = el
                    selected_slot = label.strip()
                    break
            except Exception:
                continue

    if best_el is None:
        # Fallback: first available (non-greyed-out) slot
        for el in slot_els:
            try:
                disabled = el.get_attribute("disabled") or el.get_attribute("aria-disabled")
                if disabled and disabled != "false":
                    continue
                cls = el.get_attribute("class") or ""
                if "unavailable" in cls.lower() or "disabled" in cls.lower():
                    continue
                best_el = el
                selected_slot = el.inner_text().strip()
                break
            except Exception:
                continue

    if best_el is None:
        log("  No available slots found.")
        return None

    log(f"  Selecting slot: {selected_slot!r}")
    try:
        best_el.click()
        pace()
    except Exception as e:
        log(f"  Slot click failed: {e}")
        return None

    # Confirm slot selection
    try_click(page, SEL_SLOT_CONFIRM, timeout=8000)
    pace(1500)

    if parsed:
        pref_day = parsed[0]
        if pref_day.lower() not in (selected_slot or "").lower():
            log(f"  NOTE: preferred slot ({pickup_window_pref}) unavailable — "
                f"selected nearest: {selected_slot!r}")

    return selected_slot


def add_item_to_cart(page: Page, item: dict) -> tuple[bool, Optional[str]]:
    """
    Search for one item and add it to the cart.
    Returns (success: bool, flagged_reason: str | None).
    flagged_reason is set when the item is out of stock or cannot be added.
    """
    search_term = item["search_term"]
    qty = max(1, int(item.get("default_qty") or 1))
    pack_unit = item.get("pack_unit") or ""

    log(f"  Adding: {search_term!r} (qty={qty}{' ' + pack_unit if pack_unit else ''})")

    # Fill search input
    filled = try_fill(page, SEL_SEARCH, search_term)
    if not filled:
        reason = f"Could not find search bar for '{search_term}'"
        log(f"    FLAGGED: {reason}")
        return False, reason

    page.keyboard.press("Enter")
    pace(SEARCH_WAIT_MS)

    # Check for out-of-stock on the first result
    oos_count = 0
    for sel in SEL_OUT_OF_STOCK:
        oos_count += page.locator(sel).count()
        if oos_count > 0:
            break

    # Find the Add button on the first product card
    add_btn = None
    for sel in SEL_ADD_BTN:
        els = page.locator(sel)
        if els.count() > 0:
            add_btn = els.first
            break

    if add_btn is None:
        reason = f"No 'Add' button found for '{search_term}' — may be out of stock or not carried"
        log(f"    FLAGGED: {reason}")
        return False, reason

    # Log the matched button's text so we can verify SEL_ADD_BTN hit the right button
    try:
        btn_text = add_btn.inner_text().strip()
        btn_label = add_btn.get_attribute("aria-label") or ""
        log(f"    Add button matched → text={btn_text!r} aria-label={btn_label!r}")
    except Exception:
        pass

    # Dismiss any modal that may be blocking the Add button
    dismiss_modals(page)

    # Click Add once; for qty > 1, click the increment button
    try:
        add_btn.click()
        pace(CART_SETTLE_MS)
    except Exception as e:
        reason = f"Click 'Add' failed for '{search_term}': {e}"
        log(f"    FLAGGED: {reason}")
        return False, reason

    # Increment quantity if needed (most UIs show a +/- after the first Add)
    if qty > 1:
        increment_sel = [
            '[data-testid*="increment"]',
            '[aria-label*="Increase" i]',
            'button:has-text("+")',
        ]
        for _ in range(qty - 1):
            clicked = try_click(page, increment_sel, timeout=3000)
            if not clicked:
                log(f"    Could not increment qty for '{search_term}' — stopping at 1")
                break
            pace(300)

    log(f"    Added {qty}x {search_term!r}")
    return True, None


def capture_cart_summary(page: Page, run_key: str) -> tuple[Optional[float], Optional[str], Optional[str]]:
    """
    Navigate to / open the cart to capture the subtotal and a screenshot.
    Returns (cart_total, screenshot_path, cart_url).
    """
    log("Capturing cart summary...")

    # Try to open the cart sidebar / navigate to cart page
    try_click(page, SEL_CART_BTN, timeout=8000)
    pace(1500)

    cart_url = page.url

    # Read the cart total
    total_text = try_text(page, SEL_CART_TOTAL, timeout=10000)
    cart_total = parse_price(total_text)
    log(f"  Cart total text: {total_text!r} → parsed: {cart_total}")

    # Screenshot
    SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
    screenshot_path = str(SCREENSHOT_DIR / f"{run_key}.png")
    try:
        page.screenshot(path=screenshot_path, full_page=False)
        log(f"  Screenshot saved: {screenshot_path}")
    except Exception as e:
        log(f"  Screenshot failed: {e}")
        screenshot_path = None

    return cart_total, screenshot_path, cart_url


# ─── Previous Purchases ────────────────────────────────────────────────────────

def _normalize_words(text: str) -> frozenset:
    """Return significant words from text as a lowercase frozenset, stop words removed."""
    words = set(re.sub(r"[^a-z0-9 ]", "", text.lower()).split())
    return frozenset(words - PREV_STOP_WORDS)


def _words_match(sw: str, pw: str) -> bool:
    """True if search word and product word are the same or differ only by a trailing 's'."""
    return sw == pw or sw.rstrip("s") == pw or sw == pw.rstrip("s")


def _match_score(search_term: str, product_name: str) -> float:
    """
    Fraction of significant words in search_term that appear in product_name.
    Basic plural handling (chicken ↔ chickens, breast ↔ breasts).
    """
    s_words = _normalize_words(search_term)
    p_words = _normalize_words(product_name)
    if not s_words:
        return 0.0
    matched = sum(1 for sw in s_words if any(_words_match(sw, pw) for pw in p_words))
    return matched / len(s_words)


def _navigate_to_previous_purchases(page: Page) -> bool:
    """
    Navigate to the Previous Purchases section of Food Lion To Go.
    Tries direct URL first; falls back to clicking the My Items nav link.
    Returns True if the page loaded (even if empty).
    """
    # Fast path: direct URL
    try:
        page.goto(PREV_PURCHASES_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
        pace(1500)
        dismiss_modals(page)
        try_click(page, SEL_PREV_PURCHASES_TAB, timeout=4000)
        pace(1000)
        current = page.url
        if any(kw in current.lower() for kw in ("past-purchases", "past_purchases", "my_items", "previous")):
            log(f"  Navigated to Past Purchases: {current}")
            return True
    except Exception as e:
        log(f"  Direct URL to Past Purchases failed: {e}")

    # Fallback: click My Items link from store page
    try:
        page.goto(FOODLION_TOGO_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
        pace(1500)
        dismiss_modals(page)
        clicked = try_click(page, SEL_MY_ITEMS_LINK, timeout=8000)
        if clicked:
            pace(1500)
            log(f"  Navigated to Past Purchases via nav link: {page.url}")
            return True
    except Exception as e:
        log(f"  Nav-link approach to Past Purchases failed: {e}")

    log("  Past Purchases page not accessible — all items will use search")
    return False


def _collect_prev_purchase_items(page: Page) -> list:
    """
    Scroll through the Previous Purchases page and return a list of
    {name: str, card_sel: str} for every visible product card.

    Food Lion's Past Purchases uses a horizontal carousel layout — cards are
    arranged side-by-side in a scrollable container, not stacked vertically.
    We scroll carousel containers horizontally to reveal all cards, then fall
    back to window vertical scroll for any lazy-loaded sections beneath.
    """
    # Horizontal scroll on the PDL carousel containers to trigger lazy loading.
    # After scrolling right, reset to 0 so all lazy-loaded cards are reachable.
    carousel_js = """
        () => {
            var sels = ['.pdl-carousel_slider', '.pdl-carousel_container', '[class*="carousel"]'];
            for (var i=0; i<sels.length; i++) {
                var els = document.querySelectorAll(sels[i]);
                for (var j=0; j<els.length; j++) {
                    if (els[j].scrollWidth > els[j].clientWidth) {
                        els[j].scrollLeft = els[j].scrollWidth;
                    }
                }
            }
        }
    """
    for _ in range(4):
        page.evaluate(carousel_js)
        pace(500)
    # Reset to reveal everything from the start
    page.evaluate("""
        () => {
            var sels = ['.pdl-carousel_slider', '.pdl-carousel_container', '[class*="carousel"]'];
            for (var i=0; i<sels.length; i++) {
                document.querySelectorAll(sels[i]).forEach(function(el) { el.scrollLeft = 0; });
            }
        }
    """)
    pace(500)

    # Vertical scroll for any lazy-loaded sections below the carousel
    for _ in range(3):
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        pace(500)
    page.evaluate("window.scrollTo(0, 0)")
    pace(500)

    items = []
    for card_sel in SEL_PREV_PRODUCT_CARD:
        cards = page.locator(card_sel)
        count = cards.count()
        if count == 0:
            continue
        log(f"  Found {count} card(s) using: {card_sel}")
        for i in range(count):
            try:
                card = cards.nth(i)
                name = None
                for name_sel in SEL_PREV_PRODUCT_NAME:
                    try:
                        raw = card.locator(name_sel).first.inner_text(timeout=800).strip()
                        # The PDL button includes price/size after a newline; strip it.
                        name = raw.split("\n")[0].strip() if raw else None
                        if name:
                            break
                    except Exception:
                        continue
                if name:
                    items.append({"name": name, "card_sel": card_sel})
            except Exception:
                continue
        if items:
            break

    return items


def _click_add_in_prev_card(page: Page, prev_item: dict, qty: int) -> bool:
    """
    Find the product card matching prev_item['name'] and click its Add button.
    Uses filter(has_text=) to locate the card by its name text rather than a
    stale index — robust against dynamic list reordering after scrolling.
    Returns True on success.
    """
    card_sel = prev_item["card_sel"]
    name = prev_item["name"]

    try:
        card = page.locator(card_sel).filter(has_text=name).first
        card.scroll_into_view_if_needed(timeout=5000)
        pace(300)

        add_btn = None
        for sel in SEL_ADD_BTN:
            btn = card.locator(sel)
            if btn.count() > 0:
                add_btn = btn.first
                break

        if add_btn is None:
            log(f"    No Add button found in card for '{name}'")
            return False

        dismiss_modals(page)
        add_btn.click()
        pace(CART_SETTLE_MS)

        if qty > 1:
            inc_sel = [
                '[data-testid*="increment"]',
                '[aria-label*="Increase" i]',
                'button:has-text("+")',
            ]
            for _ in range(qty - 1):
                if not try_click(page, inc_sel, timeout=3000):
                    break
                pace(300)

        return True

    except Exception as e:
        log(f"    Error adding '{name}' from Previous Purchases: {e}")
        return False


def add_from_previous_purchases(page: Page, items: list) -> dict:
    """
    Navigate to Food Lion's Previous Purchases section, match shopping items
    to products there by word-overlap score, add matched items directly,
    then return the rest for the normal search-based flow.

    Returns:
        added:           list[dict] — items added from Previous Purchases
        remaining:       list[dict] — items that need search-based adding
        available_count: int — total items visible on the Previous Purchases page
    """
    log("=== Previous Purchases pass ===")

    if not _navigate_to_previous_purchases(page):
        return {"added": [], "remaining": list(items), "available_count": 0}

    prev_items = _collect_prev_purchase_items(page)
    available_count = len(prev_items)
    log(f"  {available_count} item(s) visible in Previous Purchases")

    if not prev_items:
        page.goto(FOODLION_TOGO_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
        pace(1500)
        dismiss_modals(page)
        return {"added": [], "remaining": list(items), "available_count": 0}

    added = []
    remaining = []

    for item in items:
        search_term = item["search_term"]
        qty = max(1, int(item.get("default_qty") or 1))

        best_match = None
        best_score = 0.0
        for prev in prev_items:
            score = _match_score(search_term, prev["name"])
            if score > best_score:
                best_score = score
                best_match = prev

        if best_match and best_score >= PREV_MATCH_THRESHOLD:
            log(f"  Match ({best_score:.0%}): '{search_term}' → '{best_match['name']}'")
            if _click_add_in_prev_card(page, best_match, qty):
                added.append(item)
                log(f"    ✓ Added from Previous Purchases")
            else:
                remaining.append(item)
                log(f"    ✗ Add click failed — will search")
        else:
            score_str = f"{best_score:.0%}" if best_match else "0%"
            log(f"  No match for '{search_term}' (best {score_str}) — will search")
            remaining.append(item)

    log(f"  Pass complete: {len(added)} from prev purchases, {len(remaining)} need search")

    # Return to the main store page for the search-based adds
    page.goto(FOODLION_TOGO_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
    pace(1500)
    dismiss_modals(page)

    return {"added": added, "remaining": remaining, "available_count": available_count}


# ─── Main cart-build flow ─────────────────────────────────────────────────────

def run_build_cart(payload: dict) -> dict:
    run_key = payload.get("run_key", "unknown")
    store_name = payload.get("store_name", "")
    pickup_pref = payload.get("pickup_window_pref", "")
    spending_cap = payload.get("spending_cap_usd", 150.0)
    dry_run = payload.get("dry_run", True)
    items = payload.get("items", [])

    log(f"=== cart.py build-cart | run_key={run_key} | items={len(items)} | dry_run={dry_run} ===")

    if not items:
        return make_output("aborted", abort_reason="No items provided in cart input")

    if not AUTH_STATE_PATH.exists():
        return make_output(
            "aborted",
            abort_reason=(
                "No saved auth state found at data/playwright_state.json. "
                "Run: python3 cart_builder/cart.py --login"
            ),
        )

    flagged_items: list[str] = []
    pickup_slot: Optional[str] = None
    cart_total: Optional[float] = None
    screenshot_path: Optional[str] = None
    cart_url: Optional[str] = None
    pp_stats: Optional[dict] = None

    with sync_playwright() as p:
        browser, context = setup_context(p, headless=False)
        page = context.new_page()

        try:
            # 1. Navigate to Food Lion To Go
            navigate_to_store(page, store_name)

            # 1b. Verify session is still valid — catch Kasada/login issues early.
            # Kasada is injected by JS and can fire a few seconds after networkidle,
            # so we also verify the search bar is actually accessible before proceeding.
            # If it's not visible, we wait and re-check to catch the async Kasada fire.
            def _handle_session_state(state: str) -> str:
                if state == "kasada_challenge":
                    log("Kasada challenge detected — attempting CapSolver auto-solve...")
                    if solve_kasada_challenge(page):
                        log("  CapSolver solved — continuing build")
                        return "valid"
                    log("  CapSolver failed — falling back to manual refresh alert")
                return state

            session_state = _handle_session_state(detect_session_state(page))

            if session_state == "valid":
                # Confirm the search bar is actually interactable — Kasada fires
                # async (2-5s after networkidle) and overlays the page. A DOM count
                # check passes even when Kasada is covering the element, so we use
                # wait_for(visible) with a 5s window to catch the async fire.
                search_visible = False
                try:
                    page.locator(SEL_SEARCH[0]).wait_for(state="visible", timeout=5000)
                    search_visible = True
                except PlaywrightTimeout:
                    pass
                if not search_visible:
                    log("Search bar not interactable — Kasada may have fired async, re-checking...")
                    session_state = _handle_session_state(detect_session_state(page))

            if session_state != "valid":
                log(f"Session issue: {session_state} — aborting build, refresh required")
                return make_output("session_expired", abort_reason=session_state)

            # 1c. Clear any items left from a previous run before adding fresh
            clear_cart(page)

            # 2. Ensure pickup mode
            set_pickup_mode(page)
            pace()

            # 3. Select pickup slot
            pickup_slot = select_pickup_slot(page, pickup_pref)
            if pickup_slot:
                log(f"Pickup slot confirmed: {pickup_slot}")
            else:
                log("WARNING: Pickup slot not confirmed — continuing without slot selection")
            pace()

            # 4. Add items — Previous Purchases first, search-based fallback for the rest
            log(f"Adding {len(items)} item(s) to cart...")
            prev_result = add_from_previous_purchases(page, items)
            pp_stats = {
                "available": prev_result["available_count"],
                "matched": len(prev_result["added"]),
                "search_adds": len(prev_result["remaining"]),
            }
            if prev_result["added"]:
                log(f"  {len(prev_result['added'])}/{len(items)} item(s) added from Previous Purchases")

            for item in prev_result["remaining"]:
                pace(STEP_DELAY_MS)
                success, flagged_reason = add_item_to_cart(page, item)
                if not success:
                    flagged_items.append(flagged_reason or item["search_term"])

            # 5. Capture cart summary
            cart_total, screenshot_path, cart_url = capture_cart_summary(page, run_key)

            # 6. Spending cap check (defence-in-depth; Ruby also checks before calling us)
            if cart_total is not None and cart_total > spending_cap:
                log(f"SPENDING CAP EXCEEDED: ${cart_total:.2f} > ${spending_cap:.2f} — aborting")
                return make_output(
                    "aborted",
                    abort_reason=f"Cart total ${cart_total:.2f} exceeds cap ${spending_cap:.2f}",
                    cart_total=cart_total,
                    pickup_slot=pickup_slot,
                    flagged_items=flagged_items,
                    screenshot_path=screenshot_path,
                    cart_url=cart_url,
                    previous_purchases_stats=pp_stats,
                )

        except Exception as exc:
            log(f"Unexpected error during cart build: {exc}")
            try:
                page.screenshot(
                    path=str(SCREENSHOT_DIR / f"{run_key}_error.png"),
                    full_page=False
                )
            except Exception:
                pass
            raise  # nonzero exit → Ruby treats as hard failure
        finally:
            context.close()
            browser.close()

    log(f"Cart build complete. total={cart_total} flagged={flagged_items} slot={pickup_slot!r}")
    return make_output(
        "cart_built",
        est_total=cart_total,
        cart_total=cart_total,
        pickup_slot=pickup_slot,
        flagged_items=flagged_items,
        screenshot_path=screenshot_path,
        cart_url=cart_url,
        previous_purchases_stats=pp_stats,
    )


# ─── Entrypoint ───────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Food Lion To Go Playwright cart builder"
    )
    parser.add_argument(
        "--login",
        action="store_true",
        help="Open a headed browser for one-time Food Lion login setup (saves session to data/playwright_state.json).",
    )
    args, _ = parser.parse_known_args()

    if args.login:
        return run_login()

    # Normal cart-build mode: read JSON from stdin.
    raw_stdin = sys.stdin.read()

    try:
        payload = json.loads(raw_stdin)
    except json.JSONDecodeError as e:
        log(f"cart.py: invalid JSON on stdin: {e}")
        result = make_output("aborted", abort_reason=f"invalid input JSON: {e}")
        print(json.dumps(result))
        return 0

    SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)

    result = run_build_cart(payload)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
