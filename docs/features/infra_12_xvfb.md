# Infrastructure 12 — Unraid Docker Display (Xvfb)

> **Status:** Spec — not yet implemented.
> **Must be done before Infra 13 (Docker Deployment on Unraid).**
>
> **Lifecycle:** Once implemented, remove the Implementation section and document the verified
> Docker image size impact and any Xvfb startup timing issues encountered.

---

## Goal

Provide a virtual framebuffer (Xvfb) inside the Docker container so Chrome can run "headed"
without a physical display. Food Lion's Kasada bot-detection blocks headless Chrome — `headless=False`
is non-negotiable. Unraid Docker containers have no physical display.

---

## What changes (Docker only — local dev unaffected)

macOS sets `DISPLAY` automatically. The entrypoint script is only used inside Docker.

---

## Implementation

### `docker/Dockerfile` — add Xvfb

Add `xvfb` to the existing `apt-get install` block (don't create a separate RUN layer):

```dockerfile
RUN apt-get update && apt-get install -y \
    xvfb \
    && rm -rf /var/lib/apt/lists/*
```

Set entrypoint:
```dockerfile
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "main.rb", "serve"]
```

### `docker/entrypoint.sh` — new file

```bash
#!/bin/bash
set -e

Xvfb :99 -screen 0 1280x1024x24 &
XVFB_PID=$!
export DISPLAY=:99

sleep 1

exec "$@"

kill $XVFB_PID 2>/dev/null || true
```

### `docker/docker-compose.yml` — add display env var

```yaml
environment:
  DISPLAY: ":99"
```

---

## How to verify on Unraid

1. Build and start the container: `docker compose up -d --build`
2. Check Xvfb started: `docker exec mealie-autochef ps aux | grep Xvfb`
3. Run a build-cart: `docker exec mealie-autochef bundle exec ruby main.rb build-cart --force`
4. Expected: Chrome opens (virtually), cart builds, screenshot arrives in Telegram

If Chrome fails to start: check `docker logs mealie-autochef` for "cannot open display" errors.
Verify `DISPLAY=:99` in the container: `docker exec mealie-autochef env | grep DISPLAY`.

---

## Key files

| File | Change |
|---|---|
| `docker/Dockerfile` | Add `xvfb` to apt-get; add `ENTRYPOINT` and `CMD` |
| `docker/entrypoint.sh` | New: start Xvfb, export DISPLAY, exec main process |
| `docker/docker-compose.yml` | Add `DISPLAY: ":99"` to environment |
