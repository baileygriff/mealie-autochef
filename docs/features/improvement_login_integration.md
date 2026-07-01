# Improvement — Seamless Login Integration

> **Status:** Spec complete. Not yet started.
>
> **Replaces:** CapSolver Kasada auto-solving (Option 2). CapSolver's `AntiKasadaTask`
> is not supported in their live API. 2captcha doesn't support Kasada on standard plans.
> Automated solver services are not a viable path.
>
> **Goal:** Make login a seamless part of every `build-cart` run, fully integrated through
> Telegram. Since Kasada fires on every automated browser session, login must happen at the
> start of each cart build — not as a separate manual pre-step.

---

## Context

Food Lion's Kasada bot-detection challenges the browser on every new automated session,
regardless of whether login cookies are still valid. The `playwright_state.json` auth state
doesn't prevent Kasada from re-challenging. As a result, every `build-cart` run that starts
from a saved session hits Kasada and either stalls or falls back to Option 1's Telegram alert.

The correct model: always run a fresh login at the start of each build. This removes the
dependency on `playwright_state.json` for auth state and gives each run a clean, human-verified
session.

Running on Unraid (headless Docker), Bailey accesses everything via Telegram on his phone.
The login flow must accommodate:
- **Kasada slider challenge** — visual, requires interacting with a draggable element
- **2FA code** — 6-digit code from authenticator app, can be sent via Telegram

---

## Path A — Automated Slider + Telegram 2FA

**Try this first.** No infrastructure changes required. If Playwright's mouse simulation can
pass Kasada's slider check (~50% chance, Kasada checks movement patterns but the browser is
already real Chrome), the entire flow is automated except for typing the 2FA code.

### What changes

**`cart_builder/cart.py`**

1. **`run_build_cart()` always calls `run_login()` first.**
   Remove the `detect_session_state()` block at the top. Call `run_login()` instead.
   `run_login()` returns `True` on success, `False` on failure.
   On failure: `return make_output("login_failed", abort_reason="login_error")`.

2. **`run_login()` — automated Kasada slider.**
   After navigating and waiting the Kasada fire window:
   - Locate the Kasada slider element (selector: `[class*="kpsdk-slider"]`,
     `[id*="kpsdk"]`, or similar — discover via `probe_pp.py`-style script first)
   - Get bounding box of the slider track and handle
   - Simulate a human drag using Playwright's mouse API:
     ```python
     page.mouse.move(start_x + random.uniform(-3, 3), y + random.uniform(-2, 2))
     page.mouse.down()
     # Move in small steps with ease-in-out timing
     for step in range(steps):
         t = step / steps
         eased = t * t * (3 - 2 * t)  # smoothstep
         page.mouse.move(
             start_x + eased * drag_distance + random.uniform(-1, 1),
             y + random.uniform(-1, 1)
         )
         page.wait_for_timeout(random.randint(8, 18))
     page.mouse.up()
     ```
   - Total drag time: 900–1400ms randomized
   - After drag: wait 2s, re-run `detect_session_state()`
   - If `"valid"`: proceed to credentials → 2FA
   - If still blocked: write `{"event": "slider_failed"}` to state file → Path B fallback handling

3. **2FA IPC via state files.**
   When the 2FA prompt appears in the browser:
   - Write `{"event": "2fa_needed"}` to `data/cart_state.json`
   - Poll `data/cart_input.json` every 2s for `{"type": "2fa_code", "code": "XXXXXX"}`
   - Timeout after 5 minutes → `return make_output("login_failed", abort_reason="2fa_timeout")`
   - On receipt: enter code in browser, clear both files
   - Continue

   After login succeeds, clear state files, proceed to cart build as normal.

**`main.rb` — `cmd_build_cart`**

4. **Poll `data/cart_state.json` while cart.py runs.**
   Run cart.py in a background thread (already done for `/shop`). In the main thread:
   - Poll `data/cart_state.json` every 2s
   - On `"event": "2fa_needed"`:
     - Send Telegram: `"Food Lion 2FA needed — reply with your 6-digit code"`
     - Set `@pending_states[chat_id] = { action: :waiting_2fa_code }`
   - Clean up state files after cart.py exits

**`lib/autochef/notify.rb`**

5. **Handle `waiting_2fa_code` pending state.**
   When a message arrives and pending state is `:waiting_2fa_code`:
   - Validate it looks like a 6-digit code (`/^\d{6}$/`)
   - Write `{"type": "2fa_code", "code": text}` to `data/cart_input.json`
   - Reply: `"Code received — entering it now..."`
   - Clear pending state

6. **Handle `login_failed` status from cart.py.**
   Add a `send_login_failed_alert` method alongside `send_session_expired_alert`.
   Message: `"Login failed (reason: {abort_reason}). Run /login to try manually."`
   Add `/login` as a bot command that triggers `run_login()` standalone (for diagnostics).

### State files

| File | Written by | Read by | Contents |
|---|---|---|---|
| `data/cart_state.json` | cart.py | Ruby main.rb | `{"event": "2fa_needed"}` or `{"event": "slider_failed"}` |
| `data/cart_input.json` | Ruby main.rb | cart.py | `{"type": "2fa_code", "code": "123456"}` |

Both files live in `data/` (already gitignored). Cleared by cart.py on exit.

### Success criteria

- `build-cart` runs without any pre-existing `playwright_state.json` session
- Kasada slider is cleared automatically by Playwright mouse simulation
- Bot sends Telegram "Enter your 2FA code" prompt
- Bailey replies with code → bot passes to cart.py → login completes
- Cart builds and cart-ready Telegram message fires as normal

### Failure mode

If the automated slider doesn't pass Kasada: `detect_session_state()` still returns
`"kasada_challenge"` after the drag. Cart.py writes `{"event": "slider_failed"}` to
`data/cart_state.json`. Ruby sends a Telegram alert: `"Kasada slider couldn't be automated.
See Path B (noVNC) in the spec — Infra 12 required."` This is the prompt to do Path B.

---

## Path B — noVNC Remote Browser (depends on Infra 12)

**Fall back to this if Path A's slider automation consistently fails.** Requires Infra 12
(Xvfb in Docker) as a prerequisite, extended with noVNC and x11vnc.

### How it works

Instead of automating the slider, the bot sends Bailey a link to a noVNC web interface.
Bailey opens it on his phone browser, drags the slider with his finger, and the bot detects
completion automatically.

```
[build-cart triggered]
   → login starts, Kasada slider appears
   → cart.py writes {"event": "slider_needed"} to data/cart_state.json
   → Ruby sends Telegram:
       "Kasada challenge — solve it here:
        http://192.168.1.64:6080"
   → Bailey opens link on phone, drags slider
   → cart.py polls detect_session_state() until "valid"
   → cart.py writes {"event": "slider_cleared"} to data/cart_state.json
   → Ruby edits Telegram message: "Challenge cleared ✅ — continuing..."
   → proceeds to 2FA (same as Path A step 3)
   → cart builds normally
```

### Infrastructure additions (extends Infra 12)

Infra 12 adds Xvfb to the Docker container. Path B additionally requires:

**`docker/entrypoint.sh`** (extends Infra 12's script):
```bash
# Start virtual display (Infra 12)
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99

# Start VNC server pointing at virtual display (Path B addition)
x11vnc -display :99 -forever -nopw -shared -rfbport 5900 -quiet &

# Start noVNC websocket proxy (Path B addition)
/opt/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080 &
```

**`docker/docker-compose.yml`** additions:
```yaml
ports:
  - "6080:6080"   # noVNC web interface
  # 5900 (VNC) does not need to be exposed externally
```

**`docker/Dockerfile`** additions:
```dockerfile
RUN apt-get install -y x11vnc novnc
```

**Tailscale access:** Since Tailscale is already on Unraid, Bailey can access
`http://192.168.1.64:6080/vnc.html` from his phone browser over Tailscale without
exposing port 6080 to the internet.

### cart.py changes (Path B)

- When `detect_session_state()` still returns `"kasada_challenge"` after Path A attempt:
  - Write `{"event": "slider_needed"}` to `data/cart_state.json`
  - Poll `detect_session_state()` every 3s (up to 5 minutes)
  - When `"valid"`: write `{"event": "slider_cleared"}`, continue to credentials + 2FA
  - On timeout: `return make_output("login_failed", abort_reason="slider_timeout")`

### Ruby/Telegram changes (Path B)

- Ruby polls for `"slider_needed"` event in `data/cart_state.json`
- Sends noVNC link message (edits same message when `"slider_cleared"` arrives)
- Rest of flow (2FA) is identical to Path A

---

## Implementation order

1. **Path A first** — implement `run_login()` always-on + automated slider + Telegram 2FA IPC.
   Run `build-cart` and observe whether the slider passes.
2. **If Path A slider works** — done. Ship it.
3. **If Path A slider consistently fails** — do Infra 12 first, then Path B additions.
   Path B shares the 2FA IPC from Path A; only the slider-handling branch changes.

---

## Key files

| File | Change |
|---|---|
| `cart_builder/cart.py` | `run_build_cart()` → always calls `run_login()`; slider automation; state file writes |
| `main.rb` | `cmd_build_cart` polls `data/cart_state.json`; passes 2FA code to `cart_input.json` |
| `lib/autochef/notify.rb` | `waiting_2fa_code` handler; `send_login_failed_alert`; `/login` command |
| `data/cart_state.json` | New — IPC event file (cart.py → Ruby) |
| `data/cart_input.json` | New — IPC input file (Ruby → cart.py) |
| `docker/entrypoint.sh` | Path B: x11vnc + noVNC startup |
| `docker/docker-compose.yml` | Path B: port 6080 |
| `docker/Dockerfile` | Path B: x11vnc + novnc packages |
