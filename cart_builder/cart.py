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
    "pickup_window_pref": str,
    "spending_cap_usd": float,
    "cart_deviation_alert_pct": float,
    "dry_run": bool,
    "items": [
      {"search_term": str, "default_qty": int, "pack_unit": str | null}
    ]
  }

OUTPUT_SCHEMA (stdout, JSON):
  {
    "status": "cart_built" | "aborted",
    "abort_reason": str | null,        # set when status == "aborted"
    "est_total": float | null,
    "cart_total": float | null,
    "pickup_slot": str | null,
    "flagged_items": [str],            # out-of-stock / unmapped, never silently substituted
    "screenshot_path": str | null,
    "cart_url": str | null
  }

This file is a Phase 0 stub: it validates and echoes the contract so the
Ruby side (cart_client.rb) can be built and tested against a predictable
shape before Phase 5 implements the real Playwright flow.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    raw_stdin = sys.stdin.read()

    try:
        payload = json.loads(raw_stdin)
    except json.JSONDecodeError as e:
        print(f"cart.py: invalid JSON on stdin: {e}", file=sys.stderr)
        result = {
            "status": "aborted",
            "abort_reason": f"invalid input JSON: {e}",
            "est_total": None,
            "cart_total": None,
            "pickup_slot": None,
            "flagged_items": [],
            "screenshot_path": None,
            "cart_url": None,
        }
        print(json.dumps(result))
        return 0  # malformed input is a flagged abort, not a crash

    print(f"cart.py: received {len(payload.get('items', []))} items (Phase 0 stub — no real cart action taken)", file=sys.stderr)

    # Phase 0 stub: prove the contract round-trips. Phase 5 replaces this
    # with the real Playwright flow per MEALIE_AUTOMATION_PLAN.md section 8.13.
    result = {
        "status": "aborted",
        "abort_reason": "cart.py is a Phase 0 stub — Playwright flow not yet implemented",
        "est_total": None,
        "cart_total": None,
        "pickup_slot": None,
        "flagged_items": [],
        "screenshot_path": None,
        "cart_url": None,
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
