#!/bin/sh
# Container health: the engine answers HTTP on its port. Any status counts —
# a 404 from an app with no index page is still a live engine. Set
# RUSTCFML_HEALTHCHECK_PATH (e.g. /health) to require a 2xx/3xx from that path
# instead. Unix-socket deployments have no TCP port to probe, so they report
# healthy and leave the check to the proxy in front.
set -u
[ -n "${RUSTCFML_SOCKET:-}" ] && exit 0
PORT="${RUSTCFML_PORT:-8500}"
if [ -n "${RUSTCFML_HEALTHCHECK_PATH:-}" ]; then
  exec curl -fsS -o /dev/null --max-time 4 "http://127.0.0.1:${PORT}${RUSTCFML_HEALTHCHECK_PATH}"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:${PORT}/" || true)"
[ -n "$code" ] && [ "$code" != "000" ]
