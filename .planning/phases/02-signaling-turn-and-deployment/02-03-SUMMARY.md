---
phase: 02-signaling-turn-and-deployment
plan: "03"
subsystem: docker-deployment
tags: [docker, dockerfile, coturn, docker-compose, nginx, deployment, turn, infra]
status: complete

dependency_graph:
  requires:
    - 02-01 (server Cargo.toml deps — axum, tokio-rustls, etc. already locked)
  provides:
    - docker/Dockerfile.server (multi-stage Rust build image)
    - docker/coturn/turnserver.conf (coturn use-auth-secret config)
    - docker-compose.yml (3-service orchestration)
    - .env.example (secret template, committed without real values)
    - client/dist/index.html (nginx volume placeholder)
  affects:
    - .gitignore (added .env entry — T-02-07 mitigation)
    - Cargo.lock (committed accumulated changes from Plans 02-01/02-02 dep additions)

tech_stack:
  added:
    - coturn/coturn:4.6 Docker image (official)
    - nginx:alpine Docker image (static file server)
    - rust:1-slim builder stage
    - debian:bookworm-slim runtime stage (CLAUDE.md-locked)
  patterns:
    - Docker multi-stage build with dep-cache layer (Cargo.toml before src)
    - coturn network_mode: host — no ports: block (RESEARCH.md Pitfall 2 / D-07)
    - TURN secret in .env only; injected via ${VAR} substitution and --static-auth-secret CLI arg

key_files:
  created:
    - docker/Dockerfile.server
    - docker/coturn/turnserver.conf
    - docker-compose.yml
    - .env.example
    - client/dist/index.html
  modified:
    - .gitignore
    - Cargo.lock

decisions:
  - "coturn network_mode: host with NO ports: block — silently ignored in host mode (Pitfall 2, D-07)"
  - "static-auth-secret injected via --static-auth-secret CLI arg in docker-compose.yml command; not set in turnserver.conf — avoids committing any secret value"
  - "Cargo.lock committed with accumulated changes from Plans 02-01/02-02 (T-01-02: supply chain pinning)"

metrics:
  duration: "6 min"
  completed: "2026-07-07"
  tasks_completed: 3
  files_changed: 7
---

# Phase 02 Plan 03: Docker Deployment Configuration Summary

**One-liner:** Multi-stage Dockerfile builds the Rust server binary; coturn runs with host networking and use-auth-secret; nginx serves the client placeholder; all three services compose-up from a single `docker compose up` with secrets injected via .env.

## What Was Built

### docker/Dockerfile.server — multi-stage Rust build

- Stage 1 (`FROM rust:1-slim AS builder`): installs `pkg-config libssl-dev`, copies workspace Cargo manifests first for Docker layer caching, compiles a stub binary to warm the dep cache, then copies actual `server/src/` and builds the real release binary.
- Stage 2 (`FROM debian:bookworm-slim`): installs `ca-certificates`, copies the binary to `/usr/local/bin/immersive-rt-server`. No certs baked in — bind-mounted at runtime. EXPOSE 4433/udp, 9090/tcp, 8081/tcp. CMD runs the server directly.
- `docker build -f docker/Dockerfile.server -t immersive-rt-server-test .` exits 0 (verified).

### docker/coturn/turnserver.conf — coturn use-auth-secret configuration

- Directives: `lt-cred-mech`, `use-auth-secret`, `fingerprint`, `no-multicast-peers`
- `realm=immersivert.local`, `min-port=49152`, `max-port=65535`
- `log-file=stdout` for container-friendly logging
- **No `static-auth-secret=` directive** — the secret is passed exclusively via `--static-auth-secret=${TURN_SHARED_SECRET}` in the docker-compose.yml command array (T-02-07 mitigation).

### docker-compose.yml — 3-service orchestration

**service `server`:**
- Build context: repo root, dockerfile: `docker/Dockerfile.server`
- Ports: 4433/udp (WT), 9090/tcp (WS), 8081/tcp (HTTP credential endpoint)
- Environment: all via `${VAR}` substitution from .env; TURN_SHARED_SECRET never hardcoded
- Volume: `./certs:/certs:ro`
- `depends_on: coturn`, `restart: unless-stopped`

**service `coturn`:**
- `image: coturn/coturn:4.6`
- `network_mode: "host"` — mandatory for STUN NAT reflection (STATE.md D-07)
- **No `ports:` block** — silently ignored in host mode; would create false confidence (RESEARCH.md Pitfall 2)
- Volume: `./docker/coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro`
- Command injects `--external-ip=${COTURN_EXTERNAL_IP}` and `--static-auth-secret=${TURN_SHARED_SECRET}`

**service `static-files`:**
- `image: nginx:alpine`, port 8080:80
- Volume: `./client/dist:/usr/share/nginx/html:ro`

`docker compose config --quiet` exits 0.

### .env.example

Template committed with placeholder values; real `.env` is gitignored. Contains: `TURN_SHARED_SECRET`, `COTURN_EXTERNAL_IP`, `CERT_PATH`, `KEY_PATH`, `WT_PORT`, `WS_PORT`, `HTTP_PORT`.

### client/dist/index.html

Minimal HTML5 placeholder satisfying the nginx volume mount (`./client/dist:/usr/share/nginx/html:ro`). Prevents nginx container startup failure before Phase 4 client is built.

### .gitignore update

Added `.env` entry — ensures the real secret file is never committed (T-02-07 mitigation).

### Cargo.lock

Committed accumulated changes from Plans 02-01/02-02 where new Cargo.toml dependencies (dashmap, hmac, sha1, base64, tokio-rustls, rustls-pemfile, axum) were added but Cargo.lock was not committed. Per STATE.md decision "Cargo.lock committed to repo to pin exact crate versions (T-01-02)".

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Cargo.lock not committed with Plan 02-01/02-02 dependency additions**
- **Found during:** Task 1 git status (Cargo.lock showed as modified with 398-line diff)
- **Issue:** Plans 02-01 and 02-02 added 7 new dependencies to `server/Cargo.toml` and ran `cargo test`, updating Cargo.lock on the host, but Cargo.lock was not staged or committed in either plan.
- **Fix:** Included Cargo.lock in the Task 1 commit. Per STATE.md accumulated decision "Cargo.lock committed to repo to pin exact crate versions — T-01-02 supply chain tampering mitigation."
- **Files modified:** `Cargo.lock`
- **Commit:** d5dbc81

None of the three planned files required logic deviations — plan executed exactly as specified.

## Known Stubs

- `client/dist/index.html` is intentionally a placeholder. The real Three.js desktop client is Phase 4 scope. The nginx volume mount works correctly with this file; the stub is documented and tracked.

## Threat Flags

| Flag | File | Description |
|------|------|-------------|
| threat_flag: secret_injection | docker-compose.yml | TURN_SHARED_SECRET flows from .env → coturn --static-auth-secret CLI arg and server environment; mitigated per T-02-07 (.env gitignored, .env.example has placeholder only) |

Mitigations confirmed active:
- T-02-07: .env gitignored; no secret value in turnserver.conf or docker-compose.yml (${VAR} only)
- T-02-08: `fingerprint` directive present in turnserver.conf
- T-02-09: coturn service has no `ports:` block alongside `network_mode: host`
- T-02-10: nginx HTTP accepted for Phase 2 (noted as deferred to Phase 4 per threat register)

## Self-Check: PASSED

Files exist on disk:
- docker/Dockerfile.server: FOUND
- docker/coturn/turnserver.conf: FOUND
- docker-compose.yml: FOUND
- .env.example: FOUND
- client/dist/index.html: FOUND

Commits verified in git log:
- d5dbc81: feat(02-03): add multi-stage Dockerfile for Rust server (INFRA-07)
- 5706be4: feat(02-03): add coturn turnserver.conf with use-auth-secret config (D-07, INFRA-06)
- 638bbd2: feat(02-03): add docker-compose.yml, .env.example, client placeholder (D-07, INFRA-06, INFRA-07)
