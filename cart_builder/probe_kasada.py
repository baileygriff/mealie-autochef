"""
probe_kasada.py — inspect the Kasada challenge DOM to find slider selectors.
Run with: source .venv/bin/activate && python3 cart_builder/probe_kasada.py
Takes ~10s. No cart operations.
"""

import sys, os, json, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from playwright.sync_api import sync_playwright

FOODLION_TOGO_URL = "https://www.foodlion.com/shop"
STATE_PATH = "data/playwright_state.json"
SCREENSHOT_OUT = "data/probe_kasada.png"

STEALTH_ARGS = [
    "--disable-blink-features=AutomationControlled",
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-dev-shm-usage",
    "--disable-gpu",
]

def log(msg): print(msg, flush=True)

def run():
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=False, args=STEALTH_ARGS)
        context = browser.new_context(
            storage_state=STATE_PATH if os.path.exists(STATE_PATH) else None,
            user_agent=(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/127.0.0.0 Safari/537.36"
            ),
            viewport={"width": 1280, "height": 900},
            ignore_https_errors=True,
        )
        context.add_init_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
        page = context.new_page()

        log(f"Navigating to {FOODLION_TOGO_URL}...")
        page.goto(FOODLION_TOGO_URL, wait_until="domcontentloaded", timeout=30000)
        log("Waiting 8s for Kasada to fire...")
        page.wait_for_timeout(8000)

        page.screenshot(path=SCREENSHOT_OUT)
        log(f"Screenshot saved: {SCREENSHOT_OUT}")

        log("\n=== Page info ===")
        log(f"URL:   {page.url}")
        log(f"Title: {page.title()}")
        body_text = page.evaluate("document.body.innerText")
        log(f"body.innerText[:200]: {repr(body_text[:200])}")

        log("\n=== Frames ===")
        for i, frame in enumerate(page.frames):
            log(f"  frame[{i}]: url={frame.url}  name={frame.name}")
            try:
                ft = frame.evaluate("document.body.innerText[:100]") if frame != page.main_frame else None
            except:
                ft = None

        log("\n=== Iframes in DOM ===")
        iframes = page.query_selector_all("iframe")
        log(f"  {len(iframes)} iframe(s) found")
        for i, fr in enumerate(iframes):
            try:
                src = fr.get_attribute("src")
                bb = fr.bounding_box()
                log(f"  iframe[{i}]: src={src}  bbox={bb}")
            except Exception as e:
                log(f"  iframe[{i}]: error: {e}")

        log("\n=== Shadow DOM probe ===")
        shadow_info = page.evaluate("""() => {
            function collectShadows(root, depth=0, results=[]) {
                const all = root.querySelectorAll('*');
                for (const el of all) {
                    if (el.shadowRoot) {
                        const tag = el.tagName.toLowerCase();
                        const cls = el.className ? String(el.className).slice(0,80) : '';
                        results.push({depth, tag, cls, children: el.shadowRoot.children.length});
                        collectShadows(el.shadowRoot, depth+1, results);
                    }
                }
                return results;
            }
            return collectShadows(document);
        }""")
        if shadow_info:
            log(f"  Found {len(shadow_info)} shadow root(s):")
            for s in shadow_info:
                log(f"    depth={s['depth']} <{s['tag']}> class='{s['cls']}' shadow_children={s['children']}")
        else:
            log("  No shadow roots found in main document")

        log("\n=== Slider selector probe (main frame) ===")
        SLIDER_CANDIDATES = [
            '[class*="slider"]',
            '[class*="drag"]',
            '[class*="handle"]',
            '[role="slider"]',
            'button[class*="arrow"]',
            'button[style*="cursor"]',
            '[class*="kpsdk"]',
            '[class*="kasada"]',
            '[class*="challenge"]',
            '[class*="verification"]',
            'input[type="range"]',
            # Try text content
            ':text("Slide")',
            ':text("right")',
        ]
        for sel in SLIDER_CANDIDATES:
            try:
                els = page.query_selector_all(sel)
                if els:
                    log(f"  FOUND {len(els)}x '{sel}':")
                    for el in els[:3]:
                        bb = el.bounding_box()
                        tag = el.evaluate("el => el.tagName")
                        cls = el.get_attribute("class") or ""
                        log(f"    <{tag}> class='{cls[:60]}' bbox={bb}")
            except Exception as e:
                log(f"  Error testing '{sel}': {e}")

        log("\n=== Captcha iframe DOM probe ===")
        captcha_frame = next(
            (f for f in page.frames if 'captcha-delivery.com' in f.url or 'datadome' in f.url),
            None
        )
        if captcha_frame:
            log(f"  Found captcha frame: {captcha_frame.url[:80]}...")

            # Dump all elements with class attributes
            log("\n  All elements with class in captcha frame:")
            frame_els = captcha_frame.evaluate("""() => {
                return Array.from(document.querySelectorAll('*')).map(el => ({
                    tag: el.tagName.toLowerCase(),
                    id: el.id || '',
                    cls: el.className ? String(el.className).slice(0,80) : '',
                    role: el.getAttribute('role') || '',
                    text: el.innerText ? el.innerText.slice(0,40) : '',
                    bbox: el.getBoundingClientRect()
                })).filter(e => e.cls || e.role || e.id);
            }""")
            for el in frame_els:
                bb = el['bbox']
                if bb['width'] > 0 and bb['height'] > 0:
                    log(f"    <{el['tag']}> id='{el['id']}' class='{el['cls']}' role='{el['role']}' text='{el['text']}' bbox=({bb['x']:.0f},{bb['y']:.0f} {bb['width']:.0f}x{bb['height']:.0f})")

            log("\n  Button elements in captcha frame:")
            buttons = captcha_frame.evaluate("""() => {
                return Array.from(document.querySelectorAll('button, [role="button"]')).map(b => ({
                    tag: b.tagName.toLowerCase(),
                    cls: b.className ? String(b.className).slice(0,80) : '',
                    text: b.innerText ? b.innerText.slice(0,40) : '',
                    bbox: b.getBoundingClientRect()
                }));
            }""")
            log(f"  {len(buttons)} button(s) found:")
            for b in buttons:
                log(f"    <{b['tag']}> class='{b['cls']}' text='{b['text']}' bbox={b['bbox']}")

            log("\n  Slider-specific selectors in captcha frame:")
            for sel in [
                '[class*="slider"]', '[class*="drag"]', '[class*="handle"]',
                'input[type="range"]', '[role="slider"]',
                '[class*="captcha"]', '[class*="puzzle"]', '[class*="token"]',
                '[class*="arrow"]', 'div[style*="cursor"]', 'span[style*="cursor"]',
            ]:
                try:
                    els = captcha_frame.query_selector_all(sel)
                    if els:
                        log(f"  FOUND {len(els)}x '{sel}':")
                        for el in els[:3]:
                            bb = el.bounding_box()
                            cls = el.get_attribute("class") or ""
                            log(f"    class='{cls[:80]}' bbox={bb}")
                except Exception as e:
                    log(f"  Error '{sel}': {e}")
        else:
            log("  No captcha-delivery.com frame found")

        log("\n=== Full DOM tag inventory (top-level + shadow) ===")
        dom_inventory = page.evaluate("""() => {
            const tags = {};
            function walk(root) {
                for (const el of root.querySelectorAll('*')) {
                    const t = el.tagName.toLowerCase();
                    tags[t] = (tags[t]||0) + 1;
                    if (el.shadowRoot) walk(el.shadowRoot);
                }
            }
            walk(document);
            return tags;
        }""")
        interesting = {k:v for k,v in dom_inventory.items() if v > 0}
        log(f"  Tags found: {json.dumps(interesting, indent=2)}")

        log("\n=== All button elements with class/text ===")
        buttons = page.evaluate("""() => {
            return Array.from(document.querySelectorAll('button')).map(b => ({
                class: b.className,
                text: b.innerText.slice(0,50),
                role: b.getAttribute('role'),
                bbox: b.getBoundingClientRect()
            }));
        }""")
        log(f"  {len(buttons)} button(s) in main document:")
        for b in buttons:
            log(f"    class='{b['class'][:60]}' text='{b['text']}' bbox={b['bbox']}")

        log("\n=== Captcha frame variant detection ===")
        if captcha_frame:
            try:
                frame_body = captcha_frame.evaluate("document.body.innerText").lower()
                if "slide right" in frame_body or "slide to verify" in frame_body:
                    log("  SLIDER VARIANT — slider challenge present, selectors should match")
                elif "temporarily restricted" in frame_body or "access is" in frame_body:
                    log("  HARD BLOCK VARIANT — no slider; bot activity too frequent")
                else:
                    log(f"  UNKNOWN VARIANT — body: {frame_body[:100]!r}")
            except Exception as e:
                log(f"  Could not read captcha frame body: {e}")

        log("\nDone. Check probe_kasada.png for the visual state.")
        context.close()
        browser.close()

if __name__ == "__main__":
    run()
