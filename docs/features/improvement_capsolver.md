# Improvement — CapSolver Kasada Auto-solving (Option 2)

> **Status:** Spec — not yet implemented.
>
> **Lifecycle:** Once implemented, remove the Implementation Plan section, fill in actual solve rates,
> API costs observed, and any operational notes about Kasada token injection changes.

---

## Goal

Automatically solve Kasada bot-detection challenges during Food Lion cart builds using the CapSolver
API, eliminating the need for manual browser intervention for the `kasada_challenge` failure mode.

---

## Background

Two distinct failure modes exist during cart builds:

| Mode | Cause | Fix |
|---|---|---|
| `kasada_challenge` | Kasada bot-detection showed a challenge page | CapSolver auto-solve |
| `login_required` | Session cookie genuinely expired | Manual re-login (Option 1 alert) |

Option 2 only fires for `kasada_challenge`. `login_required` always falls through to the Option 1
Telegram alert regardless of whether CapSolver is configured.

**Option 1 (already built):** `detect_session_state()` in `cart.py` catches both failure modes and
sends a Telegram alert with `[✅ Session Refreshed → Rebuild Cart]`. Option 2 is an automatic
layer on top — if CapSolver is configured, it fires first; on failure it falls back to the Option 1
alert. Cart build is deferred, never lost.

**Why not FlareSolverr (already on Unraid)?** FlareSolverr is Cloudflare-specific
(CF_Clearance, Turnstile). Food Lion uses Kasada — a different vendor with an incompatible
challenge protocol. FlareSolverr has no Kasada support.

**Cost:** ~$0.001/solve at weekly frequency — negligible.

---

## Trigger

Automatic when `CAPSOLVER_API_KEY` is set in `.env`. No config.yaml toggle needed — remove the
key to disable.

---

## Implementation plan

### 1. Install CapSolver Python SDK

Add to `cart_builder/requirements.txt`:
```
capsolver>=1.0.0
```
Then: `source .venv/bin/activate && pip install -r cart_builder/requirements.txt`

### 2. Add to `.env`

```
CAPSOLVER_API_KEY=CAP-xxxxxxxxxxxxxxxxxxxxxxxx
```

### 3. `cart_builder/cart.py` — new `solve_kasada_challenge(page)` function

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
        page.evaluate(f"window.__kpsdk_answer = '{solution.get('token', '')}'")
        page.reload(wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
        pace(2000)
        return detect_session_state(page) == "valid"
    except Exception as e:
        log(f"  CapSolver: failed — {e}")
        return False
```

> **Note:** The exact CapSolver task type and token injection method for Kasada should be verified
> at implementation time against the current CapSolver docs. Kasada's client-side API changes
> periodically.

### 4. `run_build_cart()` — attempt solve before returning `session_expired`

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

### 5. `main.rb` / `notify.rb`

No changes needed — the `session_expired` fallback path from Option 1 handles the CapSolver
failure case automatically.

---

## CapSolver setup (do this when implementing)

1. Go to https://capsolver.com and create an account
2. Top up balance — $5 is enough for years of weekly use at ~$0.001/solve
3. Dashboard → API Key → copy your key
4. Add `CAPSOLVER_API_KEY=CAP-your-key-here` to `.env`
5. `source .venv/bin/activate && pip install capsolver`
6. Test: `python3 -c "import capsolver; capsolver.api_key='CAP-your-key'; print(capsolver.balance())"`

**Unraid note:** `CAPSOLVER_API_KEY` goes in Docker env vars (same as other secrets). No VNC or
display needed — CapSolver solves over HTTPS.

---

## Key files

- `cart_builder/requirements.txt` — add `capsolver>=1.0.0`
- `cart_builder/cart.py` — `solve_kasada_challenge()`, update `run_build_cart()` logic
- `.env` / `.env.example` — `CAPSOLVER_API_KEY`
