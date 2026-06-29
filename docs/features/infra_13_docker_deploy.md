# Infrastructure 13 — Docker Deployment on Unraid

> **Status:** Blocked — depends on Infra 12 (Xvfb) being in place first.
>
> **Lifecycle:** Once deployed and stable, fill in actual Unraid Docker template settings,
> volume mount paths, and any network configuration specifics.

---

## Goal

Deploy the autochef Ruby container to Bailey's Unraid box (192.168.1.64) running alongside the
existing Mealie container on the `mealie_net` Docker network.

---

## Prerequisites

- Infra 12 (Xvfb) must be done first — Chrome will fail to start in a containerless display
- Confirmed stable local operation
- `playwright_state.json` refreshed and working

---

## Key configuration changes vs. local dev

| Setting | Local dev | Docker on Unraid |
|---|---|---|
| `MEALIE_URL` | `http://192.168.1.64:3000` | `http://mealie:9000` (on `mealie_net`) |
| `CART_BUILDER_PYTHON` | `/path/to/.venv/bin/python3` | Dockerfile-managed venv path |
| `playwright_state.json` | Local file | Volume-mounted (persists across restarts) |
| `DISPLAY` | Set by macOS automatically | `:99` (set by entrypoint.sh) |

---

## Known considerations

- `playwright_state.json` **must be volume-mounted** so Food Lion session persists across
  container restarts. Rebuilding the image should not log Bailey out of Food Lion.
- Mealie URL switches from `http://192.168.1.64:3000` to `http://mealie:9000` on `mealie_net`.
  `MEALIE_URL` in `.env` overrides `config.yaml`.
- **TODO (test after deploy):** "⚙ Configure week" button URL uses `web.host` (192.168.1.64).
  Verify the link opens correctly from Telegram once the container is running on Unraid.
- The SQLite DB at `data/autochef.db` should also be volume-mounted for persistence.
- Secrets (`.env` contents) go in Unraid's Docker template environment variables.

---

## Key files

| File | Status |
|---|---|
| `docker/Dockerfile` | Exists; update after Infra 12 is done |
| `docker/docker-compose.yml` | Exists; update `MEALIE_URL`, volumes |
| `docker/entrypoint.sh` | Created in Infra 12 |
