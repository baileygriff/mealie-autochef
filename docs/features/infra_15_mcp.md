# Infrastructure 15 — MCP Setup

> **Status:** Deferred — waiting for Docker deployment (Infra 13) to be stable.
>
> **Lifecycle:** Once set up, document the MCP server config and which container operations
> are available via Claude Code.

---

## Goal

Set up a Docker MCP server so Claude Code can manage autochef containers directly from a
development session — without needing to SSH into Unraid or use the Unraid web UI.

---

## Prerequisites

- Infra 13 (Docker Deployment on Unraid) must be stable first

---

## Scope (TBD at implementation time)

The MCP Docker server typically exposes: container list, start/stop/restart, exec (run a command
inside a container), and log tailing. Useful operations for this project:
- `docker exec mealie-autochef bundle exec ruby main.rb check`
- `docker exec mealie-autochef bundle exec ruby main.rb plan`
- Tailing autochef container logs
- Restarting the container after a config change

---

## Open questions (to resolve when implementing)

1. Which MCP Docker server to use? (official Docker MCP, or a community implementation)
2. Should it run on Unraid itself, or on the local dev machine pointing at the remote Docker socket?
3. What permissions / which operations should be exposed vs. locked down?

---

## Key files

- MCP server config (path TBD — likely `.claude/mcp.json` or similar)
- Possibly Unraid-side Docker socket exposure config
