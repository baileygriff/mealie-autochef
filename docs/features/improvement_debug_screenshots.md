# Improvement — Debug Screenshots

> **Status:** ✅ Implemented (twenty-fourth session).

---

## Goal

Take screenshots at each meaningful step of the cart build process and keep a rolling window of
the last 2 full run directories, so debugging a failed or suspicious build is possible without
re-running.

---

## Directory layout

```
data/cart_screenshots/
├── <run_key>/                  # debug dir for one run (rolling: last 2 kept)
│   ├── 01_store_loaded.png     # after navigate_to_store + modal dismissal
│   ├── 02_cart_cleared.png     # after clear_cart
│   ├── 03_pickup_mode.png      # after set_pickup_mode
│   ├── 04_slot_selected.png    # after select_pickup_slot
│   ├── 05_item_01_<term>.png   # after each successful search-based add
│   ├── 05_item_02_<term>.png
│   ├── ...
│   ├── 06_cart_summary.png     # after capture_cart_summary
│   └── error.png               # on any exception (also saved at root as <run_key>_error.png)
└── <run_key>.png               # final cart screenshot (Telegram notification only)
```

**Rolling window:** At the start of `run_build_cart()`, `_rolling_cleanup_debug_dirs()` deletes
all but the most recent subdirectory. Creating the new run's dir makes it 2 total (current + one
prior run).

**Item numbering:** `item_num` starts from the count of Previous Purchases adds. Search-based adds
continue the numbering so screenshots span the full add sequence.

---

## Optional env var

`DEBUG_SCREENSHOTS_PATH` — if set in `.env`, the per-run debug dir is copied there after
completion (useful for a network share or NAS mount). Not yet implemented; the env var is
documented in `.env.example` as a placeholder.

---

## Key files

- `cart_builder/cart.py` — `_debug_screenshot()`, `_rolling_cleanup_debug_dirs()`,
  `run_build_cart()` calls
- `.env.example` — `DEBUG_SCREENSHOTS_PATH` documented
