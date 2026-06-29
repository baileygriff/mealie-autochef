# Improvement — Debug Screenshots

> **Status:** Spec — not yet implemented.
>
> **Lifecycle:** Once implemented, remove the Implementation Plan section and document the actual
> directory layout, rolling window behavior, and any env var usage.

---

## Goal

Take screenshots at each meaningful step of the cart build process and keep a rolling window of
the last 2 full run directories, so debugging a failed or suspicious build is possible without
re-running.

---

## Screenshots to capture (in order)

1. After `navigate_to_store` + modal dismissal — confirm we're on the right page
2. After `clear_cart` — confirm cart is empty
3. After `set_pickup_mode` — confirm pickup tab active
4. After each `add_item_to_cart` success — confirm item appeared in cart count
5. After `capture_cart_summary` — final cart view (same as current `run_key.png`)
6. On any exception — error screenshot (already exists)

---

## Implementation plan

### `cart.py` — per-step screenshots with rolling cleanup

```python
debug_dir = SCREENSHOT_DIR / run_key
debug_dir.mkdir(parents=True, exist_ok=True)
page.screenshot(path=str(debug_dir / "01_store_loaded.png"))
```

**Rolling window:** At the start of `run_build_cart()`, list all subdirectories of `SCREENSHOT_DIR`
sorted by mtime. If more than 1 exists, delete the oldest. This keeps the last 2 full run
directories.

The final summary screenshot (`run_key.png`) stays as-is for the Telegram notification.

### Optional env var

`DEBUG_SCREENSHOTS_PATH`: if set, rsync/copy the debug run directory there after completion.

---

## Key files

- `cart_builder/cart.py` — `run_build_cart()`: per-step screenshots, rolling cleanup, optional
  copy to `DEBUG_SCREENSHOTS_PATH`
- `.env.example` — document `DEBUG_SCREENSHOTS_PATH`
