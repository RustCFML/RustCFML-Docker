#!/bin/sh
# End-to-end check of a built image: it serves, it stops on SIGINT quickly, the
# extension warm step refuses a broken .rcx, and honours STRICT=0.
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
