---
phase: quick/260707-f1x
plan: 01
subsystem: developer-tooling
status: complete
tags: [makefile, docker, certs, permissions, cold-start]
completed: 2026-07-07T10:58:08Z
duration: 112s

dependency_graph:
  requires: []
  provides: [Makefile, docker-compose-usage-comment]
  affects: [docker-compose.yml]

tech_stack:
  added: []
  patterns: [self-documenting-makefile, idempotent-chmod]

key_files:
  created:
    - Makefile
  modified:
    - docker-compose.yml

decisions:
  - Use idempotent chmod o+r in _ensure-certs so make up is safe to run on certs at any existing permission level
  - Security note documenting world-readable key trade-off placed inline in Makefile above each chmod call
  - _ensure-certs is an internal target (no ## annotation) so it is omitted from make help output

metrics:
  duration: 112s
  tasks_completed: 2
  tasks_total: 2
  files_changed: 2
---

# Phase quick/260707-f1x Plan 01: Fix cert permissions for cold start — Summary

**One-liner:** Makefile with idempotent `chmod o+r` in `make up` so the Dockerised server can always read the mkcert private key.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create Makefile with dev-certs and up targets | 2086ce3 | Makefile (created) |
| 2 | Update docker-compose.yml usage comment to reference make up | 8c57396 | docker-compose.yml |

## What Was Built

### Makefile (new)

Canonical developer entry point for the ImmersiveRT stack. Targets:

- `make help` — self-documenting list via `## comment` grep pattern
- `make dev-certs` — runs `mkcert -key-file ... -cert-file ... localhost 127.0.0.1 ::1`, then `chmod o+r` on both cert files; exits 1 with install hint if mkcert is absent
- `make _ensure-certs` — internal; verifies key exists (exit 1 with hint if not), then silently (`@chmod`) applies `chmod o+r` idempotently
- `make up` — depends on `_ensure-certs`, then `docker compose up --build`
- `make down` — `docker compose down`

Security notes are documented inline above each `chmod o+r` call explaining that world-readable permissions are acceptable only for dev-only locally-trusted mkcert certs.

### docker-compose.yml (comment update)

Replaced bare `docker compose up --build` in the Usage block with:
```
#   make dev-certs                          # generate certs + fix permissions (run once)
#   make up                                 # start the full stack
```

No YAML structure or values changed.

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check

- [x] Makefile exists: `/home/ivancist/Documents/immersiveRT/.claude/worktrees/agent-a5646af5b0fae2114/Makefile`
- [x] `make --dry-run dev-certs` includes mkcert invocation
- [x] `make --dry-run up` includes docker compose
- [x] `make --dry-run _ensure-certs` includes chmod
- [x] `make help` lists dev-certs, up, down with descriptions
- [x] docker-compose.yml contains `make up` in usage comment
- [x] `docker compose config` validates (warnings only for missing env vars, expected without .env)
- [x] Commits 2086ce3 and 8c57396 exist in git log
- [x] No unexpected file deletions

## Self-Check: PASSED

## Known Stubs

None.

## Threat Flags

No new network endpoints, auth paths, file access patterns, or schema changes introduced. The `chmod o+r` behaviour is addressed by T-f1x-01 in the plan's threat register (accepted: dev-only localhost certs, documented in Makefile).
