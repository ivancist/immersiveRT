---
phase: 03-session-and-pairing
plan: "03"
subsystem: infrastructure/nginx
tags: [nginx, https, tls, spa-routing, docker-compose, mkcert]
dependency_graph:
  requires:
    - Phase 01 Plan 02 (mkcert certs generated at certs/localhost+2.pem)
    - docker-compose.yml static-files service (pre-existing)
  provides:
    - HTTPS on port 8443 for camera-app-scannable QR codes (D-13)
    - SPA fallback routing for /room/ABCD paths (D-06)
    - nginx config mounted via docker-compose volume
  affects:
    - Phase 03 Plan 04 (join-ack pairing_url must use https://localhost:8443)
    - SESS-01, SESS-02, SESS-03 (QR pairing flow depends on HTTPS nginx)
tech_stack:
  added:
    - docker/nginx/nginx.conf — nginx SPA + HTTPS config
  patterns:
    - nginx try_files $uri /index.html for SPA routing
    - nginx SSL with mkcert certs via volume mount
    - docker-compose volume:ro for security (T-03-08)
key_files:
  created:
    - docker/nginx/nginx.conf
  modified:
    - docker-compose.yml
decisions:
  - "nginx static-files service listens on both 80 (HTTP) and 443 (HTTPS) in a single server block — minimal config, no separate HTTP-to-HTTPS redirect needed for Phase 3"
  - "PAIRING_TOKEN_SECRET and BASE_URL added to server environment block in docker-compose.yml to document required vars for Phase 3 Plan 04"
  - "certs/ volume mounted :ro (not under document root) — T-03-08 mitigated; nginx cannot serve cert files as static assets"
metrics:
  duration: 2 min
  completed_date: "2026-07-07"
  tasks_completed: 2
  files_changed: 2
status: complete
---

# Phase 03 Plan 03: nginx HTTPS + SPA Routing Summary

**One-liner:** nginx static-files service upgraded to HTTPS on port 8443 via mkcert certs + try_files SPA fallback for /room/* paths.

## What Was Built

Added `docker/nginx/nginx.conf` and updated `docker-compose.yml` to give the nginx static-files service:

1. **HTTPS on port 8443** — required for iOS/Android camera apps to auto-open QR-scanned pairing URLs (D-13, RESEARCH.md Pitfall 5). Certificate paths reference the mkcert-generated `localhost+2.pem` / `localhost+2-key.pem` that already exist from Phase 1.
2. **HTTP on port 8090** — preserved for non-phone local testing (existing behavior).
3. **SPA routing** — `try_files $uri /index.html` serves static assets directly and falls back to `index.html` for all non-file paths including `/room/ABCD`, `/phone`, etc. (D-06).

## Verification Results

```
docker compose up -d static-files → Started (Recreated from prior state)

curl -sk https://localhost:8443/              → 200
curl -sk https://localhost:8443/room/ABCD23  → 200   (SPA fallback)
curl -s  http://localhost:8090/              → 200
```

All three success criteria from the plan's verification block are met.

## Key Files

| File | Change |
|------|--------|
| `docker/nginx/nginx.conf` | Created — single server block with HTTP+HTTPS, mkcert certs, try_files SPA fallback |
| `docker-compose.yml` | static-files service: added port 8443:443, two new volume mounts (nginx.conf, certs); server service: added PAIRING_TOKEN_SECRET and BASE_URL env vars |

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| Task 1 — nginx.conf | c43ed80 | feat(03-03): add nginx HTTPS + SPA routing config |
| Task 2 — docker-compose.yml | 29f78f4 | feat(03-03): expose HTTPS port 8443 and add nginx/certs mounts to static-files |

## Deviations from Plan

### Minor — Verification Criteria Discrepancy (auto-noted, no action taken)

**Found during:** Task 2 verification
**Issue:** The plan's done criteria for Task 2 states `grep -c '8443' docker-compose.yml returns 1`, but the plan's own action instructions required adding both a `"8443:443"` port mapping AND a `BASE_URL` comment that also references `8443`. The actual result is 2 matches.
**Resolution:** Both occurrences are intentional per the plan's action steps. The actual implementation is correct; the verification count in the plan was off-by-one. No code change was made.

## Threat Mitigations Applied

| Threat ID | Mitigation Implemented |
|-----------|------------------------|
| T-03-05 | nginx serves HTTPS on 8443 with mkcert certs; BASE_URL is a documented required env var with no HTTP default |
| T-03-08 | `./certs:/certs:ro` — read-only mount, certs not placed under `/usr/share/nginx/html` document root |

## LAN Phone Testing Note

The current `localhost+2.pem` cert covers `localhost 127.0.0.1 ::1`. For testing with a real phone on the LAN, the device cannot reach `localhost` — you must regenerate certs with the machine's LAN IP in the SAN (e.g. `mkcert localhost 127.0.0.1 ::1 192.168.1.x`) and set `BASE_URL=https://192.168.1.x:8443`. This is documented in RESEARCH.md Pitfall 3 and deferred to a Makefile `dev-certs` update.

## Self-Check: PASSED

- [x] `docker/nginx/nginx.conf` exists — verified via `grep -c try_files` (1) and `grep -c ssl_certificate` (2)
- [x] `docker-compose.yml` updated with port 8443:443 and volume mounts — verified via `docker compose config` (exit 0)
- [x] Commits c43ed80 and 29f78f4 exist in git log
- [x] curl tests returned 200 for HTTP, HTTPS, and /room/ABCD23 SPA path
