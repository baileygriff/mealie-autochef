# Improvement — CapSolver Kasada Auto-solving (Option 2)

> **Status:** Code complete (twenty-third/twenty-fifth sessions). Blocked on proxy setup —
> tinyproxy on Unraid + router port-forward needed before first live test.
>
> **Lifecycle:** Once verified end-to-end, remove the Setup sections, fill in actual solve
> rates, observed API costs, and any Kasada token-injection notes if the field names changed.

---

## What this does

Automatically solves Food Lion's Kasada bot-detection challenge during cart builds, so the
weekly run never requires manual browser intervention for the `kasada_challenge` case.

When `CAPSOLVER_API_KEY` is set and Kasada is detected, `cart.py` submits the page URL to
CapSolver, receives a token, injects it, reloads the page, and re-checks session state. If
CapSolver succeeds, the build continues without interruption. If it fails for any reason,
Option 1 (Telegram alert + inline rebuild button) fires as the fallback — the build is
deferred, never lost.

---

## Background

Two failure modes exist during `build-cart`:

| Mode | Cause | CapSolver handles? |
|---|---|---|
| `kasada_challenge` | Kasada slider / JS challenge blocked the page | Yes — Option 2 auto-solves |
| `login_required` | Session cookies genuinely expired | No — Option 1 Telegram alert always |

**Why a proxy is required:** Kasada's token is IP-bound — it's valid only for the IP that
originally requested the challenge page. CapSolver's servers are not at your home IP
(70.131.45.67), so they need a proxy that routes their solving request through your Unraid
box to get a token that will work for your browser. Without it, CapSolver returns
`InvalidRequestError: unable to process task request`.

**Why not FlareSolverr (already on Unraid)?** FlareSolverr is Cloudflare-specific
(CF_Clearance, Turnstile). Food Lion uses Kasada — a different vendor. FlareSolverr has
no Kasada support.

**Cost:** ~$0.001/solve at weekly frequency. The $6 already loaded will last years.

---

## What's already done

- `CAPSOLVER_API_KEY` set in `.env` ✅
- `capsolver>=1.0.0` in `requirements.txt` ✅
- `solve_kasada_challenge(page)` implemented in `cart_builder/cart.py` ✅
- `_handle_session_state()` in `run_build_cart()` calls CapSolver before falling back to Option 1 ✅
- `CAPSOLVER_PROXY` env var read in `solve_kasada_challenge()` ✅
- Kasada detection timing fixed (6s wait before check) ✅ — confirmed working in live run
- Live test confirmed: CapSolver fires, submits task, fails only because proxy is missing ✅

---

## What's needed to go live

1. tinyproxy running as a Docker container on Unraid
2. Router port-forward: external port 8888 → Unraid 192.168.1.64:8888
3. `CAPSOLVER_PROXY` set in `.env`
4. One `build-cart --force` run to verify end-to-end

---

## Proxy setup on Unraid

### Why tinyproxy

tinyproxy is a minimal HTTP/HTTPS forward proxy — a single small process that takes an
incoming HTTP request and forwards it out. When CapSolver connects to your tinyproxy, the
outgoing request goes through Unraid → your router → internet from IP 70.131.45.67. That
satisfies Kasada's IP-matching requirement. tinyproxy has no web UI and almost no config —
it's the right tool for this single-purpose job.

---

### Step 1 — Create the tinyproxy config file

Create `docker/tinyproxy.conf`:

```
Port 8888
Listen 0.0.0.0
Timeout 600
MaxClients 10
MinSpareServers 1
MaxSpareServers 5
StartServers 2
DisableViaHeader Yes

# Basic auth — only requests with these credentials are forwarded.
# Change the password to something strong before deploying.
BasicAuth capsolver CHANGE_THIS_PASSWORD
```

> The `BasicAuth` line means CapSolver must supply `capsolver:CHANGE_THIS_PASSWORD` to use
> the proxy. Without it the proxy is an open relay — anyone who finds the port can use it.
> Pick a random 20+ character password and use it consistently in the next step.

---

### Step 2 — Add tinyproxy to docker-compose.yml

In `docker/docker-compose.yml`, add a `tinyproxy` service alongside `autochef`:

```yaml
  tinyproxy:
    image: vimagick/tinyproxy
    container_name: autochef-tinyproxy
    volumes:
      - ./tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro
    ports:
      - "8888:8888"
    restart: unless-stopped
```

The port mapping `"8888:8888"` makes tinyproxy reachable at `192.168.1.64:8888` on your
LAN. After the router port-forward (Step 3), it will also be reachable at `70.131.45.67:8888`
from the internet.

> **Note:** tinyproxy does not need to be on `mealie_net` — it does not talk to Mealie.
> It only accepts incoming connections (from CapSolver) and forwards them outbound.

---

### Step 3 — Router port-forward

In your router's port-forwarding settings (same section where Mealie/Jellyfin/Immich are forwarded):

| Field | Value |
|---|---|
| External port | 8888 |
| Internal IP | 192.168.1.64 (Unraid) |
| Internal port | 8888 |
| Protocol | TCP |

This is the same process as forwarding any other self-hosted service. The exact menu path
varies by router brand — look for "Port Forwarding", "Virtual Server", or "NAT" in your
router's admin UI.

---

### Step 4 — Set CAPSOLVER_PROXY in .env

```
CAPSOLVER_PROXY=http://capsolver:CHANGE_THIS_PASSWORD@70.131.45.67:8888
```

Use the same password you put in `tinyproxy.conf`. The format is:
`http://username:password@host:port`

---

### Step 5 — Verify the proxy works before testing CapSolver

Before running a cart build, confirm tinyproxy is routing correctly:

```bash
# From any machine (Mac, Unraid shell, wherever):
curl --proxy "http://capsolver:CHANGE_THIS_PASSWORD@70.131.45.67:8888" https://ifconfig.me
```

Expected output: `70.131.45.67` (your outgoing IP). If you see a different IP or an error,
the proxy or port-forward isn't set up correctly — fix this before proceeding.

---

### Step 6 — Test CapSolver end-to-end

```bash
bundle exec ruby main.rb build-cart --force 2>&1
```

**Success looks like:**
```
[cart_builder] Kasada challenge detected — attempting CapSolver auto-solve...
[cart_builder]   CapSolver: using proxy (70.131.45.67:8888)
[cart_builder]   CapSolver: submitting AntiKasadaTask...
[cart_builder]   CapSolver: solution keys → ['token', ...]
[cart_builder]   CapSolver: injecting token (N chars)
[cart_builder]   CapSolver: challenge cleared successfully
[cart_builder]   CapSolver solved — continuing build
```
...followed by the normal cart-building output (items added, $X total).

**Failure — proxy not reachable:**
```
CapSolver: solve failed — ConnectionError: ...
```
→ Check `curl` test from Step 5. Port-forward or tinyproxy not up.

**Failure — wrong credentials:**
```
CapSolver: solve failed — InvalidRequestError: ...
```
→ Confirm password in `tinyproxy.conf` matches `CAPSOLVER_PROXY` in `.env`.

**Failure — CapSolver can't solve this Kasada variant:**
```
CapSolver: solve failed — ...
CapSolver failed — falling back to manual refresh alert
```
→ Option 1 Telegram alert fires. This is the correct fallback. Note the error and
check CapSolver's dashboard for task failure details.

---

## After a successful test

Once the end-to-end solve is confirmed:

1. Check CapSolver balance: `python3 -c "import capsolver; capsolver.api_key='CAP-...'; print(capsolver.balance())"`
2. Update this spec: remove Setup sections, add observed solve rate and cost per solve
3. Update `TESTING_HANDOFF.md` to mark CapSolver as ✅

---

## Integration with Docker deployment (Infra 13)

When deploying autochef to Unraid via Docker:

- `CAPSOLVER_API_KEY` goes in Unraid's Docker template env vars (same as other secrets)
- `CAPSOLVER_PROXY` goes in the same env vars:  
  `http://capsolver:PASSWORD@autochef-tinyproxy:8888`  
  *(use the container name `autochef-tinyproxy` as the host when both containers are on
  the same Docker network — no need for the public IP internally)*
- tinyproxy is already in `docker-compose.yml` from Step 2 above

---

## Key files

| File | Status |
|---|---|
| `cart_builder/cart.py` — `solve_kasada_challenge()` | ✅ implemented |
| `cart_builder/requirements.txt` — `capsolver>=1.0.0` | ✅ done |
| `.env` — `CAPSOLVER_API_KEY` | ✅ set |
| `.env` — `CAPSOLVER_PROXY` | ⏳ set after proxy is up |
| `.env.example` — `CAPSOLVER_PROXY` | ⏳ add after proxy is up |
| `docker/tinyproxy.conf` | ⏳ create (Step 1) |
| `docker/docker-compose.yml` — tinyproxy service | ⏳ add (Step 2) |
