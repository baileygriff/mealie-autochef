"""
probe_pp.py — Minimal Previous Purchases selector probe.

Use this instead of a full build-cart run when investigating what selectors
work on the Food Lion Past Purchases page. Runs in ~30s, no cart operations.

Usage:
  source .venv/bin/activate
  python3 cart_builder/probe_pp.py

Output: selector hit/miss counts + any product names found. Paste the output
into the chat so the right selectors can be confirmed and cart.py updated.
"""

import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

AUTH_STATE_PATH = Path("data/playwright_state.json")
PREV_PURCHASES_URL = "https://www.foodlion.com/past-purchases"
PAGE_LOAD_TIMEOUT_MS = 30_000


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def main():
    if not AUTH_STATE_PATH.exists():
        print("ERROR: data/playwright_state.json not found — run --login first", file=sys.stderr)
        sys.exit(1)

    with sync_playwright() as p:
        browser = p.chromium.launch(
            channel="chrome",
            headless=False,
            args=["--disable-blink-features=AutomationControlled"],
        )
        ctx = browser.new_context(storage_state=str(AUTH_STATE_PATH))
        ctx.add_init_script("Object.defineProperty(navigator,'webdriver',{get:()=>undefined})")
        page = ctx.new_page()

        log(f"Navigating to {PREV_PURCHASES_URL}...")
        page.goto(PREV_PURCHASES_URL, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
        time.sleep(2)

        # Dismiss modals
        try:
            page.mouse.click(10, 10)
            time.sleep(0.5)
        except Exception:
            pass

        log(f"URL: {page.url}")
        log(f"Title: {page.title()}")
        log("")

        # ── Horizontal scroll probe ──────────────────────────────────────────
        log("=== Horizontal scroll candidates ===")
        scroll_probe = """
            () => {
                const results = [];
                document.querySelectorAll('*').forEach(el => {
                    if (el.scrollWidth > el.clientWidth + 10) {
                        const tag = el.tagName.toLowerCase();
                        const tid = el.getAttribute('data-testid') || '';
                        const cls = (el.className || '').toString().slice(0, 60);
                        results.push(`${tag} data-testid="${tid}" class="${cls}" scrollWidth=${el.scrollWidth}`);
                    }
                });
                return results.slice(0, 20);
            }
        """
        scrollables = page.evaluate(scroll_probe)
        for s in scrollables:
            log(f"  {s}")
        if not scrollables:
            log("  (none found)")
        log("")

        # ── Card selector probe ──────────────────────────────────────────────
        # Food Lion uses PDL (Peapod Digital Labs) components — no data-testid.
        # Confirmed selector as of 2026-06-28: li.product-grid-cell (66 cards).
        card_sels = [
            'li.product-grid-cell',           # confirmed — PDL individual product card
            '.pdl-carousel_item',             # group container (5 groups × ~13 cards each)
            '[class*="product-grid-cell"]',
            '[class*="product-cell"]',
            'li[class*="tile"]',
            # Legacy data-testid fallbacks (Instacart white-label patterns)
            '[data-testid*="store-product"]',
            '[data-testid*="product-card"]',
            'article[data-testid]',
            'li[data-testid]',
        ]

        log("=== Card selector counts (before scroll) ===")
        for sel in card_sels:
            try:
                count = page.locator(sel).count()
                log(f"  {count:3d}  {sel}")
            except Exception as e:
                log(f"  ERR  {sel}: {e}")
        log("")

        # Scroll all horizontal containers
        log("Scrolling carousel containers...")
        page.evaluate("""
            () => {
                document.querySelectorAll('*').forEach(el => {
                    if (el.scrollWidth > el.clientWidth + 10) {
                        el.scrollLeft = el.scrollWidth;
                    }
                });
            }
        """)
        time.sleep(1.5)

        log("=== Card selector counts (after horizontal scroll) ===")
        for sel in card_sels:
            try:
                count = page.locator(sel).count()
                log(f"  {count:3d}  {sel}")
            except Exception as e:
                log(f"  ERR  {sel}: {e}")
        log("")

        # ── Name selector probe on first hit ────────────────────────────────
        # Confirmed selector as of 2026-06-28: [class*="product-tile_detail-title"]
        # Note: inner_text includes price/size after \n — strip at first \n.
        name_sels = [
            '[class*="product-tile_detail-title"]',  # confirmed — button with full name
            '[class*="product-grid-cell_name-text"]',  # anchor fallback
            '[data-testid*="item-name"]',
            '[data-testid*="product-name"]',
            'h2',
            'h3',
            'p',
            'span',
        ]

        best_card_sel = None
        for sel in card_sels:
            count = page.locator(sel).count()
            if count > 0:
                best_card_sel = sel
                log(f"First card selector with hits: {sel} ({count} cards)")
                break

        if best_card_sel:
            card = page.locator(best_card_sel).first
            log("=== Name selectors on first card ===")
            for nsel in name_sels:
                try:
                    text = card.locator(nsel).first.inner_text(timeout=800).strip()
                    log(f"  HIT  {nsel!r:45s}  → {text[:60]!r}")
                except Exception:
                    log(f"  miss {nsel!r}")
        else:
            log("No card selectors matched — paste the 'Horizontal scroll candidates' above")
            log("into the chat; the correct card selector can be derived from those elements.")

        log("")
        log("=== data-testid inventory (first 40) ===")
        testids = page.evaluate("""
            () => [...new Set(
                [...document.querySelectorAll('[data-testid]')]
                    .map(el => el.getAttribute('data-testid'))
            )].slice(0, 40)
        """)
        for tid in testids:
            log(f"  {tid}")

        browser.close()
        log("")
        log("Probe complete.")


if __name__ == "__main__":
    main()
