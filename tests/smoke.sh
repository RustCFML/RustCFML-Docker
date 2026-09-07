#!/bin/sh
# End-to-end check of a built image: it serves, it stops quickly on both stop
# signals, it serves through nginx when asked, the extension warm step refuses a
# broken .rcx, and honours STRICT=0.
set -eu
IMAGE="${1:-rustcfml:local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${SMOKE_PORT:-8599}"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- serve + request"
cid=$(docker run -d --rm -p "$PORT:8500" -v "$HERE/examples/hello/webroot:/app" -e RUSTCFML_MODE=dev "$IMAGE")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 40); do
  body=$(curl -s "http://127.0.0.1:$PORT/index.cfm" || true)
  [ -n "$body" ] && break
  sleep 0.25
done
echo "$body"
echo "$body" | grep -q "Hello from RustCFML" || fail "unexpected body"

echo "--- healthcheck script"
docker exec "$cid" rustcfml-healthcheck || fail "healthcheck did not pass"

echo "--- stop is fast (SIGINT)"
start=$(date +%s)
docker stop -t 10 "$cid" >/dev/null
took=$(( $(date +%s) - start ))
echo "stopped in ${took}s"
[ "$took" -lt 5 ] || fail "docker stop took ${took}s — SIGINT not honoured"
trap - EXIT

echo "--- stop is fast (SIGTERM, the signal every orchestrator sends)"
# Not covered by the SIGINT case above: as PID 1 the kernel installs no default
# signal dispositions, so an engine that does not HANDLE SIGTERM ignores it
# entirely and `docker stop` waits out the grace period before SIGKILL.
# Needs engine >= v0.653.14.
#
# Deliberately NOT `--rm`: the container must survive its own exit so
# `docker inspect` can be asked whether it stopped. With `--rm` the record is
# removed the moment it exits, inspect then errors, and a naive
# `|| echo false` fallback silently reports "still running" for a container
# that stopped instantly.
cid=$(docker run -d -p "$PORT:8500" -v "$HERE/examples/hello/webroot:/app" "$IMAGE")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/index.cfm" && break; sleep 0.25; done
start=$(date +%s)
docker kill --signal=TERM "$cid" >/dev/null
running=true
for i in $(seq 1 100); do
  running=$(docker inspect --format '{{.State.Running}}' "$cid")
  [ "$running" = "false" ] && break
  sleep 0.1
done
took=$(( $(date +%s) - start ))
if [ "$running" != "false" ]; then
  docker logs "$cid" 2>&1 | tail -5
  docker rm -f "$cid" >/dev/null 2>&1 || true
  fail "still running 10s after SIGTERM — the engine is not handling it (needs >= v0.653.14)"
fi
docker logs "$cid" 2>&1 | grep -q "SIGTERM received" || fail "engine did not report handling SIGTERM"
docker rm -f "$cid" >/dev/null; trap - EXIT
echo "stopped in ${took}s"

echo "--- nginx front (RUSTCFML_PROXY=nginx, engine on a unix socket)"
cid=$(docker run -d --rm -p "$PORT:8500" -v "$HERE/examples/hello/webroot:/app" -e RUSTCFML_PROXY=nginx "$IMAGE")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 80); do
  body=$(curl -s "http://127.0.0.1:$PORT/index.cfm" || true)
  [ -n "$body" ] && break
  sleep 0.25
done
echo "$body" | grep -q "Hello from RustCFML" || fail "nginx mode did not serve: $body"
curl -sI "http://127.0.0.1:$PORT/index.cfm" | grep -qi "^server: nginx" || fail "response did not come through nginx"
docker exec "$cid" sh -c '[ -S /run/rustcfml.sock ]' || fail "engine is not on the unix socket"
docker exec "$cid" rustcfml-healthcheck || fail "healthcheck did not pass through nginx"
docker rm -f "$cid" >/dev/null; trap - EXIT

echo "--- nginx misconfiguration is refused, not ignored"
set +e
out=$(docker run --rm -e RUSTCFML_PROXY=bogus "$IMAGE" 2>&1); rc=$?
set -e
[ "$rc" -eq 64 ] || fail "expected exit 64 for a bad RUSTCFML_PROXY, got $rc: $out"
set +e
out=$(docker run --rm -e RUSTCFML_PROXY=nginx -e RUSTCFML_SOCKET=/run/x.sock "$IMAGE" 2>&1); rc=$?
set -e
[ "$rc" -eq 64 ] || fail "expected exit 64 for PROXY=nginx + RUSTCFML_SOCKET, got $rc: $out"

echo "--- broken extension is fatal by default"
tmp=$(mktemp -d); mkdir -p "$tmp/extensions"; echo junk > "$tmp/extensions/bad-0.0.1.rcx"
cp "$HERE/examples/hello/webroot/index.cfm" "$tmp/"
set +e
out=$(docker run --rm -v "$tmp:/app" "$IMAGE" 2>&1); rc=$?
set -e
echo "$out"
[ "$rc" -eq 78 ] || fail "expected exit 78, got $rc"

echo "--- RUSTCFML_EXTENSIONS_STRICT=0 continues"
cid=$(docker run -d --rm -p "$PORT:8500" -v "$tmp:/app" -e RUSTCFML_EXTENSIONS_STRICT=0 "$IMAGE")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/index.cfm" && break; sleep 0.25; done
docker logs "$cid" 2>&1 | grep -q "1 problem" || fail "problem not reported"
curl -s "http://127.0.0.1:$PORT/index.cfm" | grep -q "Hello from RustCFML" || fail "did not serve in non-strict mode"
docker rm -f "$cid" >/dev/null; trap - EXIT
rm -rf "$tmp"

if [ -n "${SMOKE_RCX:-}" ]; then
  echo "--- real extension: $SMOKE_RCX"
  tmp=$(mktemp -d); mkdir -p "$tmp/extensions"; cp "$SMOKE_RCX" "$tmp/extensions/"
  fn="${SMOKE_RCX_FN:-hello_extGreet}"
  printf '<cfoutput>#%s( "smoke" )#</cfoutput>\n' "$fn" > "$tmp/index.cfm"
  cid=$(docker run -d --rm -p "$PORT:8500" -v "$tmp:/app" "$IMAGE")
  trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
  for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/index.cfm" && break; sleep 0.25; done
  docker logs "$cid" 2>&1 | grep -E "extensions —|Loaded extension"
  docker logs "$cid" 2>&1 | grep -q "1 loaded, 0 problem" || fail "extension did not load"
  body=$(curl -s "http://127.0.0.1:$PORT/index.cfm"); echo "$body"
  echo "$body" | grep -qi "error" && fail "extension function call failed"
  docker exec "$cid" sh -c 'ls /home/nonroot/.rustcfml/ext-cache/*/' | grep -q . || fail "ext-cache not populated"
  docker rm -f "$cid" >/dev/null; trap - EXIT; rm -rf "$tmp"
fi
echo "ALL OK"
