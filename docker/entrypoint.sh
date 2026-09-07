#!/bin/sh
# RustCFML container entrypoint.
#
# Serves $RUSTCFML_WEBROOT with `rustcfml --serve`, after checking for native
# extensions (.rcx) and warming them. The engine becomes PID 1 via exec, so the
# stop signal reaches it directly and it drains in-flight requests before exiting.
#
#   RUSTCFML_MODE        production (default) | dev
#   RUSTCFML_WEBROOT     /app
#   RUSTCFML_PORT        8500              TCP port (ignored when a socket is set)
#   RUSTCFML_SOCKET      unset             bind a Unix socket at this path instead
#   RUSTCFML_MAX_MEMORY  auto              75% of the cgroup limit; or 1.5G, 1536M, "" to disable
#   RUSTCFML_EXTENSIONS  unset             extra .rcx directory (--extensions)
#   RUSTCFML_EXTENSIONS_STRICT  1          refuse to start if an extension fails to load
#   RUSTCFML_SINGLE_THREADED    unset      set to 1 for --single-threaded
#   CFCONFIG             unset             explicit server .cfconfig.json (read by the engine)
#
# Any extra container arguments are appended to the serve command, e.g.
#   docker run ... ghcr.io/rustcfml/rustcfml --verbose
#
# Running the container with a first argument that is not a flag runs that
# rustcfml subcommand instead of serving, e.g.
#   docker run ... ghcr.io/rustcfml/rustcfml ext list
#   docker run ... ghcr.io/rustcfml/rustcfml script.cfm
set -eu

MODE="${RUSTCFML_MODE:-production}"
WEBROOT="${RUSTCFML_WEBROOT:-/app}"
PORT="${RUSTCFML_PORT:-8500}"

case "${1:-}" in
  ""|-*) ;;                                # serve
  *) exec rustcfml "$@" ;;                 # `ext list`, a .cfm file, --version …
esac

if [ ! -d "$WEBROOT" ]; then
  echo "rustcfml: webroot '$WEBROOT' does not exist (mount your app at $WEBROOT or set RUSTCFML_WEBROOT)" >&2
  exit 64
fi

# Native extensions: find them, load them once, fail loudly if one is broken.
# Same search order as the engine; the warm step extracts each library into
# $HOME/.rustcfml/ext-cache so the server's own start does not pay for it.
/usr/local/bin/rustcfml-warm-extensions

set -- "$@"
case "$MODE" in
  production) set -- --production "$@" ;;
  dev)        ;;
  *) echo "rustcfml: RUSTCFML_MODE must be 'production' or 'dev' (got '$MODE')" >&2; exit 64 ;;
esac

if [ -n "${RUSTCFML_SOCKET:-}" ]; then
  set -- --socket "$RUSTCFML_SOCKET" "$@"
else
  set -- --port "$PORT" "$@"
fi
[ -n "${RUSTCFML_EXTENSIONS:-}" ]        && set -- --extensions "$RUSTCFML_EXTENSIONS" "$@"
[ "${RUSTCFML_SINGLE_THREADED:-0}" = 1 ] && set -- --single-threaded "$@"
# RUSTCFML_MAX_MEMORY and CFCONFIG are read by the engine itself.

cd "$WEBROOT"
exec rustcfml --serve "$WEBROOT" "$@"
