#!/bin/sh
# docker-entrypoint.sh — inject TURN shared secret at runtime.
#
# The TURN_SHARED_SECRET is passed as an environment variable (not a CLI arg)
# to avoid exposing it in `ps aux`, `docker inspect`, and /proc/<pid>/cmdline.
# This script copies the read-only base config to a writable temp location,
# appends the secret, then exec-replaces itself with turnserver.
#
# Usage (set in docker-compose.yml):
#   entrypoint: ["/bin/sh", "/docker-entrypoint.sh"]
#   command: ["--external-ip=${COTURN_EXTERNAL_IP}"]
#   environment:
#     - TURN_SHARED_SECRET=${TURN_SHARED_SECRET}
set -e

if [ -z "${TURN_SHARED_SECRET}" ]; then
  echo "ERROR: TURN_SHARED_SECRET environment variable is not set" >&2
  exit 1
fi

# Copy the read-only bind-mounted config to a writable location.
cp /etc/coturn/turnserver.conf /tmp/turnserver-runtime.conf

# Append the secret — never stored in the image or on the command line.
printf '\nstatic-auth-secret=%s\n' "${TURN_SHARED_SECRET}" >> /tmp/turnserver-runtime.conf

# Replace this shell process with turnserver, forwarding any extra args
# (e.g. --external-ip from the docker-compose command: section).
exec turnserver -c /tmp/turnserver-runtime.conf "$@"
