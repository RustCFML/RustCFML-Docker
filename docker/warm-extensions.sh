#!/bin/sh
# Check for native extensions (.rcx) and warm them.
#
# The engine loads extensions once per process from, in order:
#   1. $RUSTCFML_EXTENSIONS (--extensions)
#   2. extensions.directory in the server .cfconfig.json
#   3. $RUSTCFML_WEBROOT/extensions/
#   4. $HOME/.rustcfml/extensions/
#   5. /opt/rustcfml/extensions/          (beside the binary)
# On first load each archive's library for this platform is extracted into
# $HOME/.rustcfml/ext-cache/<sha256>/. Running this script at image build time
# bakes that cache into a layer; the entrypoint runs it again at start so a
# broken or wrong-platform extension stops the container with a message
# instead of a server that silently lacks functions.
#
# Nothing to do when no .rcx exists anywhere; exits 0 quietly.
#
#   RUSTCFML_EXTENSIONS_STRICT=1 (default)  any load problem is fatal (exit 78)
#   RUSTCFML_EXTENSIONS_STRICT=0            report problems and continue
set -eu

WEBROOT="${RUSTCFML_WEBROOT:-/app}"
STRICT="${RUSTCFML_EXTENSIONS_STRICT:-1}"
BIN_DIR="$(dirname "$(readlink -f "$(command -v rustcfml)")")"

found=0
for dir in "${RUSTCFML_EXTENSIONS:-}" "$WEBROOT/extensions" "${HOME:-/nonexistent}/.rustcfml/extensions" "$BIN_DIR/extensions"; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  for f in "$dir"/*.rcx; do
    [ -e "$f" ] || continue
    found=$((found + 1))
  done
done
# A directory named only in .cfconfig.json is not visible to this shell scan;
# the probe below still loads it, so only the "nothing found" shortcut is affected.
if [ "$found" -eq 0 ] && [ -z "${CFCONFIG:-}" ] && [ ! -f "$WEBROOT/.cfconfig.json" ]; then
  exit 0
fi

set -- --verbose -c 'writeOutput("")'
[ -n "${RUSTCFML_EXTENSIONS:-}" ] && set -- --extensions "$RUSTCFML_EXTENSIONS" "$@"

# One engine start in CLI mode walks the exact loader the server uses; verbose
# prints "Loaded extension …" per success and "…warning…" per problem.
out="$(cd "$WEBROOT" && rustcfml "$@" 2>&1 | grep -v '^\[.*\] DEBUG ' || true)"

loaded="$(printf '%s\n' "$out" | grep -c '^Loaded extension ' || true)"
problems="$(printf '%s\n' "$out" | grep -i -c 'warning' || true)"

if [ "$found" -gt 0 ] || [ "$loaded" -gt 0 ] || [ "$problems" -gt 0 ]; then
  echo "rustcfml: extensions — $found .rcx found, $loaded loaded, $problems problem(s)"
  printf '%s\n' "$out" | grep -E '^Loaded extension |[Ww]arning' | sed 's/^/  /' || true
fi

if [ "$problems" -gt 0 ] && [ "$STRICT" = 1 ]; then
  echo "rustcfml: refusing to start with a broken extension (set RUSTCFML_EXTENSIONS_STRICT=0 to continue anyway)" >&2
  exit 78
fi
exit 0
