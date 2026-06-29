# Infrastructure 14 — Uptime Kuma Push Monitor

> **Status:** Waiting on Bailey — requires creating a Push monitor in Kuma and providing the URL.
>
> **Lifecycle:** Once set up, document the push URL pattern and what "healthy" looks like in the
> Kuma dashboard.

---

## Goal

Confirm `main.rb plan` ran successfully each week by having it push to an Uptime Kuma monitor.
Kuma will alert if no push is received by the expected time.

---

## Setup steps (Bailey's side)

1. Open Uptime Kuma at `http://192.168.1.64:3001`
2. Add a new **Push** monitor
3. Set the expected heartbeat interval to match the weekly schedule (e.g. 7 days + a few hours
   buffer)
4. Copy the push URL (format: `http://192.168.1.64:3001/api/push/XXXXX?status=up&msg=OK`)
5. Add to `.env`: `UPTIME_KUMA_PUSH_URL=http://192.168.1.64:3001/api/push/XXXXX?status=up&msg=OK`

---

## Code side (already stubbed)

`main.rb plan` already has a stub to POST to `UPTIME_KUMA_PUSH_URL` after a successful run.
No code changes needed — just provide the URL.

---

## Key files

- `.env` — add `UPTIME_KUMA_PUSH_URL`
- `main.rb` — stub already present; verify it fires correctly after the URL is set
