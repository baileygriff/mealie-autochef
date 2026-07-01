# Improvement — Seamless Login Integration

> **Status:** Path A implemented (28th session) and live-tested (29th–30th). **Path A confirmed
> insufficient** — automated slider drag is now geometrically correct but DataDome still rejects
> it (behavioral detection + a greylisted IP). **Decision (30th session, 2026-07-02): pivot to
> Path B (noVNC human-solve).** Path B is specced in detail below and is the next thing to build.
>
> **Replaces:** CapSolver Kasada auto-solving (Option 2). CapSolver's `AntiKasadaTask`
> is not supported in their live API. 2captcha doesn't support Kasada on standard plans.
> Automated solver services are not a viable path.
>
> **Goal:** Make login a seamless part of every `build-cart` run, fully integrated through
> Telegram. Since DataDome challenges every automated browser session, login must happen at the
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

## Path A — Live Test Results (29th–30th sessions) — CONFIRMED INSUFFICIENT

Path A was implemented (28th session) and live-tested against Food Lion's real challenge.
The vendor is **DataDome** (not Kasada — the challenge is served from a
`geo.captcha-delivery.com` cross-origin iframe). `_try_kasada_slider()` was rewritten to
locate the iframe via `page.frames`, find the `[class="slider"]` handle, and drag it.

**29th session:** slider found, drag executes, IPC verified, Telegram alert received. One bug:
the drag fell ~13px short of the target zone (`- random.uniform(5, 12)` produced ~209px).

**30th session (2026-07-02):** drag distance fixed to
`parent_w - bbox["width"] + random.uniform(3, 8)` and live-verified:

```
Kasada slider: found captcha iframe (geo.captcha-delivery.com...)
Kasada slider: dragging 221px in 22 steps ([class="slider"])
Session check: challenge frame URL detected (...same initialCid...)
Kasada slider: challenge not cleared after drag (state: kasada_challenge)
```

The drag now lands the handle center at ~752.5px — essentially dead-on the target-zone center
(~753.5px). **Distance is correct, but DataDome still rejects the slide.** Two signals explain why:

1. **Behavioral detection.** Human drags from this machine pass (that's how
   `playwright_state.json` was created originally); the synthetic smoothstep drag does not.
   DataDome fingerprints the *motion* (velocity profile, micro-timing), not just the endpoint.
2. **The IP is greylisted.** The DataDome challenge text itself lists
   *"Automated (bot) activity on your network (IP 70.131.45.67)"* as a reason. Even a perfect
   drag from a flagged IP is likely to be rejected.

**Conclusion:** Path A's automated slider cannot be made reliable from this IP. Keep the
automated attempt as a cheap best-effort first try (the corrected distance may occasionally pass
on a non-flagged session), but **the reliable path is Path B — a human solves the slider.**
Human drags pass even from the greylisted IP, so noVNC-in-the-loop will work.

---

## Path B — noVNC Remote Browser (depends on Infra 12)  ← **CHOSEN PATH**

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

### Key insight — the code side is environment-agnostic and testable locally first

The Path B interaction loop (cart.py writes `slider_needed` → human solves → cart.py polls until
cleared → writes `slider_cleared`) is **identical** whether the human solves via noVNC on their
phone (Docker/Unraid) or by dragging directly in the visible Chrome window (local Mac dev).
Only two things differ by environment, and neither requires environment detection in the code:

- **What the Telegram message says** — it can list *both* options ("drag it in the Chrome window
  if AutoChef is on your Mac, or open {noVNC URL} if it's on Unraid"). Robust everywhere.
- **Whether the noVNC infra exists** — the Docker additions (Xvfb + x11vnc + noVNC) only matter on
  Unraid. Locally, the browser is already visible.

**Therefore the code (cart.py + notify.rb + config) can be built and end-to-end tested on the
local Mac first** (human drags the visible slider when the Telegram prompt arrives — a
Bailey-gated step like 2FA). The Docker infra (Infra 12 + noVNC) is a separate, later deliverable
that only needs Bailey to verify on Unraid. Split the work this way.

### cart.py changes (Path B) — decided design

Two new functions, plus a refactor of the DataDome-handling in `_integrated_login`.

```python
def _wait_for_manual_slider(page: Page, timeout_secs: int = 300) -> bool:
    """
    Path B: ask the human to solve the DataDome slider and poll until it clears.

    Writes {"event": "slider_needed"} so the Ruby serve bot sends Bailey a Telegram
    message (noVNC link on Unraid, "drag it in the browser" on local Mac). Polls
    detect_session_state() every 3s. Read-only — never clicks — so it can't interfere
    with the human dragging. Returns True once the challenge is gone (state is no longer
    "kasada_challenge"; the outer flow re-checks for login_required), False on timeout.
    """
    log("  Path B: awaiting manual slider solve (noVNC / visible browser)...")
    _write_cart_state({"event": "slider_needed"})
    deadline = time.time() + timeout_secs
    while time.time() < deadline:
        time.sleep(3)
        state = detect_session_state(page)
        if state != "kasada_challenge":
            log(f"  Path B: challenge cleared by human (state: {state}) ✓")
            _write_cart_state({"event": "slider_cleared"})
            return True
    log("  Path B: manual solve timed out")
    _write_cart_state({"event": "slider_failed"})
    return False


def _solve_datadome(page: Page) -> bool:
    """
    Clear a DataDome challenge: try Path A (automated slider) once as a best-effort,
    then fall back to Path B (human solves). Returns True once cleared, False otherwise.
    """
    if _try_kasada_slider(page) and detect_session_state(page) != "kasada_challenge":
        return True
    return _wait_for_manual_slider(page)
```

Then, in `_integrated_login()`, replace **every** place that currently does
`if not _try_kasada_slider(page): _write_cart_state({"event": "slider_failed"}); return False`
(the top DataDome block *and* the three re-fire checks inside the `login_required` branch) with:

```python
if detect_session_state(page) == "kasada_challenge":
    if not _solve_datadome(page):
        return False
```

This makes a single build-cart run try the automated drag once, then hand off to the human —
no separate invocation, no `/login` pre-step. The old two-exit `slider_failed`/`return False`
top block collapses into one call.

### IPC events (cart.py → Ruby, via `data/cart_state.json`)

| Event | Meaning | Ruby response |
|---|---|---|
| `slider_needed` | DataDome slider is up; human must solve it | Send Telegram: noVNC link + "or drag it in the browser" |
| `slider_cleared` | Human solved it; run continuing | Send Telegram confirmation "✅ Challenge cleared — continuing…" |
| `slider_failed` | Manual solve timed out (5 min) | Existing alert + Retry button (unchanged) |
| `2fa_needed` | 2FA code required | Existing prompt (unchanged) |

### config change — noVNC URL

Add a `novnc_port` to the `web:` block (default **6080**). Build the URL as
`http://#{cfg.web.host}:#{cfg.web.novnc_port}/vnc.html`.

```ruby
# lib/autochef/config.rb — WebConfig
class WebConfig < ValidatedStruct
  attr_reader :enabled, :port, :host
  validates :port, numericality: { greater_than: 0, only_integer: true }
  validates :host, presence: true

  def novnc_port  # default when not set in config.yaml
    @novnc_port || 6080
  end
end
```

```yaml
# config.yaml — web:
web:
  enabled: false
  port: 3456
  host: "192.168.1.64"
  novnc_port: 6080   # Path B DataDome slider — noVNC web port (Docker/Unraid)
```

### notify.rb changes (Path B) — `check_cart_build_state`

Add `slider_needed` and `slider_cleared` cases. Guard re-sends with a
`@handled_cart_events` list (reset in the `unless File.exist?(CART_STATE_FILE)` branch,
replacing the current single-purpose `@slider_failure_notified` flag), since the state file
persists until cart.py clears it and the 2s scheduler re-reads it every tick.

```ruby
when 'slider_needed'
  @handled_cart_events ||= []
  return if @handled_cart_events.include?('slider_needed')
  @handled_cart_events << 'slider_needed'
  novnc = "http://#{@cfg.web.host}:#{@cfg.web.novnc_port}/vnc.html"
  bot_api.send_message(
    chat_id: @chat_id, parse_mode: 'Markdown',
    text: [
      "🧩 *DataDome slider needs solving*",
      "",
      "Drag the slider to continue the cart build:",
      "• On your Mac: drag it in the open Chrome window.",
      "• On Unraid: open #{novnc} and drag it there.",
      "",
      "I'll continue automatically once it's cleared.",
    ].join("\n")
  )
when 'slider_cleared'
  @handled_cart_events ||= []
  return if @handled_cart_events.include?('slider_cleared')
  @handled_cart_events << 'slider_cleared'
  bot_api.send_message(chat_id: @chat_id,
    text: "✅ Challenge cleared — continuing the cart build…")
```

---

## Implementation order (Path B is now the plan)

1. **Code side, tested locally first** (no Docker needed):
   - `cart.py`: add `_wait_for_manual_slider` + `_solve_datadome`; refactor `_integrated_login`.
   - `config.rb` + `config.yaml`: add `novnc_port`.
   - `notify.rb`: `slider_needed` / `slider_cleared` handlers + `@handled_cart_events` guard.
   - Verify: `bundle exec rspec` green, `python3 -c "import cart_builder.cart"` clean.
   - **Live local test (Bailey-gated drag):** run `serve` + `build-cart --force`, wait for the
     Telegram "slider needs solving" prompt, drag the slider in the visible Chrome window,
     confirm the run continues (state → `slider_cleared` → 2FA / cart build). Watch IP hard-block
     — run when the slider variant is showing (check with `probe_kasada.py` first).
2. **Infra 12 (Xvfb)** — Dockerfile `xvfb`, `entrypoint.sh`, compose `DISPLAY=:99`.
3. **Path B infra** — Dockerfile `x11vnc novnc`, entrypoint x11vnc + `novnc_proxy`, compose port
   `6080`. Verify on Unraid: open `http://192.168.1.64:6080/vnc.html` over Tailscale, drag slider.
4. **Infra 13 (Docker deploy)** — deploy to Unraid; volume-mount `data/`; `MEALIE_URL=http://mealie:9000`.

---

## Key files

| File | Change |
|---|---|
| `cart_builder/cart.py` | `_wait_for_manual_slider`, `_solve_datadome`; `_integrated_login` uses them |
| `lib/autochef/config.rb` | `WebConfig#novnc_port` (default 6080) |
| `config.yaml` | `web.novnc_port: 6080` |
| `lib/autochef/notify.rb` | `check_cart_build_state`: `slider_needed` + `slider_cleared` cases; `@handled_cart_events` guard |
| `docker/entrypoint.sh` | Infra 12: Xvfb; Path B: x11vnc + `novnc_proxy` |
| `docker/docker-compose.yml` | Path B: port 6080; Infra 12: `DISPLAY=:99` |
| `docker/Dockerfile` | Infra 12: `xvfb`; Path B: `x11vnc novnc` |
| `data/cart_state.json` | IPC event file (cart.py → Ruby): `slider_needed` / `slider_cleared` / `slider_failed` / `2fa_needed` |
| `data/cart_input.json` | IPC input file (Ruby → cart.py): 2FA code |
