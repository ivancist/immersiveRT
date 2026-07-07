SHELL := /bin/bash
CERT_DIR  := certs
CERT_FILE := $(CERT_DIR)/localhost+2.pem
KEY_FILE  := $(CERT_DIR)/localhost+2-key.pem

.PHONY: help dev-certs up down _ensure-certs

help: ## Show available make targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

dev-certs: ## Generate mkcert TLS certs for localhost and set world-read permission (run once)
	@command -v mkcert >/dev/null 2>&1 || { \
		echo "ERROR: mkcert is not installed."; \
		echo "Install instructions: https://github.com/FiloSottile/mkcert"; \
		echo "  Linux (apt):  sudo apt install mkcert && mkcert -install"; \
		echo "  macOS:        brew install mkcert && mkcert -install"; \
		exit 1; \
	}
	@mkdir -p $(CERT_DIR)
	mkcert -key-file $(KEY_FILE) -cert-file $(CERT_FILE) localhost 127.0.0.1 ::1
	@# SECURITY NOTE: chmod o+r on a private key makes it world-readable on the host.
	@# This is acceptable for dev-only mkcert certs which are locally trusted and valid
	@# only for localhost. Production cert handling must use proper secret management —
	@# do not apply this pattern to CA-signed keys.
	chmod o+r $(KEY_FILE) $(CERT_FILE)
	@echo "Certs generated in $(CERT_DIR)/. Reminder: certs/ must be gitignored — never commit private keys."

# Internal target: verify certs exist and fix permissions idempotently before docker compose up.
_ensure-certs:
	@if [ ! -f "$(KEY_FILE)" ]; then \
		echo "ERROR: cert key not found at $(KEY_FILE)"; \
		echo "Run: make dev-certs"; \
		exit 1; \
	fi
	@# SECURITY NOTE: see dev-certs target note — world-readable only for dev localhost certs.
	@chmod o+r $(KEY_FILE) $(CERT_FILE)

up: _ensure-certs ## Start the full stack (run make dev-certs first if certs are absent)
	docker compose up --build

down: ## Stop the full stack
	docker compose down
