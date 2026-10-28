#!/bin/sh
# Check for native extensions (.rcx) and warm them.
#
# The engine loads extensions once per process from, in order:
#   1. $RUSTCFML_EXTENSIONS (--extensions)
#   2. extensions.directory in the server .cfconfig.json
#   3. $RUSTCFML_WEBROOT/extensions/     (default webroot /srv/app)
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

WEBROOT="$(/usr/local/bin/rustcfml-webroot)"
# Absolute, so the link into the probe's scratch directory (below) points at it
# from anywhere, not relative to the scratch directory.
if [ -d "$WEBROOT" ]; then
  WEBROOT="$(cd "$WEBROOT" && pwd)"
fi
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

# The probe is an empty template in a scratch directory, not inline code run in
# the webroot: inline code there runs the app's Application.cfc (onApplicationStart,
# then onRequest with no page), so every container start would boot the app once
# against its database and could log an error.
#
# - An empty Application.cfc beside the probe ends the engine's upward search
#   for one, so the app's is not found even when the scratch directory is under
#   the webroot (TMPDIR inside it, or a webroot of /tmp).
# - The engine's application directory is the template's, so the webroot's
#   extensions/ is linked into the scratch directory to keep it in the search.
# - The cwd stays the webroot, so the server .cfconfig.json (and its
#   extensions.directory) is found exactly as the server finds it.
#
# With no writable temp directory (a read-only container), fall back to the
# inline probe in the webroot, which runs the app's Application.cfc as before.
probe=""
if probe="$(mktemp -d 2>/dev/null)"; then
  trap 'rm -rf "$probe"' EXIT
  : > "$probe/probe.cfm"
  printf '<cfcomponent></cfcomponent>\n' > "$probe/Application.cfc"
  [ -d "$WEBROOT/extensions" ] && ln -s "$WEBROOT/extensions" "$probe/extensions"
  set -- --verbose "$probe/probe.cfm"
else
  probe=""
  echo "rustcfml: no writable temp directory; checking extensions from the webroot, which runs its Application.cfc" >&2
  set -- --verbose -c 'writeOutput("")'
fi
[ -n "${RUSTCFML_EXTENSIONS:-}" ] && set -- --extensions "$RUSTCFML_EXTENSIONS" "$@"

# One engine start in CLI mode walks the exact loader the server uses; verbose
# prints "Loaded extension …" per success and "…warning…" per problem. Counts
# come from the engine's own output; only the lines shown are edited.
out="$(cd "$WEBROOT" && rustcfml "$@" 2>&1 | grep -v '^\[.*\] DEBUG ' || true)"

loaded="$(printf '%s\n' "$out" | grep -c '^Loaded extension ' || true)"
problems="$(printf '%s\n' "$out" | grep -i -c 'warning' || true)"

# Report the scratch link's paths as the webroot's. A literal replacement (awk
# index), so no character in either path can change what is matched.
show() {
  FROM="${probe:+$probe/extensions/}" TO="$WEBROOT/extensions/" awk '
    BEGIN { f = ENVIRON["FROM"]; t = ENVIRON["TO"] }
    {
      rest = $0; done = ""
      if (f != "") while ((i = index(rest, f)) > 0) {
        done = done substr(rest, 1, i - 1) t
        rest = substr(rest, i + length(f))
      }
      print "  " done rest
    }'
}

if [ "$found" -gt 0 ] || [ "$loaded" -gt 0 ] || [ "$problems" -gt 0 ]; then
  echo "rustcfml: extensions — $found .rcx found, $loaded loaded, $problems problem(s)"
  printf '%s\n' "$out" | grep -E '^Loaded extension |[Ww]arning' | show || true
fi

if [ "$problems" -gt 0 ] && [ "$STRICT" = 1 ]; then
  echo "rustcfml: refusing to start with a broken extension (set RUSTCFML_EXTENSIONS_STRICT=0 to continue anyway)" >&2
  exit 78
fi
exit 0
