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
#   RUSTCFML_PROXY       none              none | nginx — front the engine with nginx,
#                                          which reaches it over a unix socket
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
PROXY="${RUSTCFML_PROXY:-none}"

# The socket nginx proxies to. Internal to the container: nothing outside it
# should connect here, which is why it is not configurable.
PROXY_SOCKET=/run/rustcfml.sock

case "$PROXY" in
  none|nginx) ;;
  *) echo "rustcfml: RUSTCFML_PROXY must be 'none' or 'nginx' (got '$PROXY')" >&2; exit 64 ;;
esac

if [ "$PROXY" = nginx ]; then
  if ! command -v nginx >/dev/null 2>&1; then
    echo "rustcfml: RUSTCFML_PROXY=nginx but nginx is not installed in this image" >&2
    exit 64
  fi
  if [ -n "${RUSTCFML_SOCKET:-}" ]; then
    echo "rustcfml: RUSTCFML_SOCKET cannot be combined with RUSTCFML_PROXY=nginx." >&2
    echo "  nginx owns the public port and reaches the engine over $PROXY_SOCKET." >&2
    echo "  Publish nginx's port with RUSTCFML_PORT instead." >&2
    exit 64
  fi
fi

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

if [ "$PROXY" = nginx ]; then
  # nginx takes the public port; the engine is reachable only over the socket.
  rm -f "$PROXY_SOCKET"
  set -- --socket "$PROXY_SOCKET" "$@"
elif [ -n "${RUSTCFML_SOCKET:-}" ]; then
  set -- --socket "$RUSTCFML_SOCKET" "$@"
else
  set -- --port "$PORT" "$@"
fi
[ -n "${RUSTCFML_EXTENSIONS:-}" ]        && set -- --extensions "$RUSTCFML_EXTENSIONS" "$@"
[ "${RUSTCFML_SINGLE_THREADED:-0}" = 1 ] && set -- --single-threaded "$@"
# RUSTCFML_MAX_MEMORY and CFCONFIG are read by the engine itself.

cd "$WEBROOT"

if [ "$PROXY" != nginx ]; then
  # The engine becomes PID 1, so the stop signal reaches it directly.
  exec rustcfml --serve "$WEBROOT" "$@"
fi

# ---------------------------------------------------------------------------
# nginx mode: two processes in one container, supervised by this shell.
#
# Deliberately a shell and not s6/supervisord: there are exactly two processes,
# neither needs restarting in place (if either dies the container should die and
# be rescheduled), and a 30-line trap is easier to reason about than a
# supervision tree.
# ---------------------------------------------------------------------------
CONF=/tmp/nginx.conf
sed -e "s|__PORT__|$PORT|" -e "s|__SOCKET__|$PROXY_SOCKET|" /etc/nginx/nginx.conf > "$CONF"

engine_pid=""
nginx_pid=""

shutdown() {
  # SIGTERM drains the engine (in-flight requests finish) from v0.653.14;
  # SIGQUIT is nginx's own graceful stop.
  [ -n "$nginx_pid" ]  && kill -QUIT "$nginx_pid"  2>/dev/null || true
  [ -n "$engine_pid" ] && kill -TERM "$engine_pid" 2>/dev/null || true
}
trap shutdown TERM INT

rustcfml --serve "$WEBROOT" "$@" &
engine_pid=$!

# nginx exits immediately if its upstream socket is missing at startup, so wait
# for the engine to create it. A cold boot compiles the application, so allow
# generously and fail loudly rather than leaving a container that never serves.
i=0
while [ ! -S "$PROXY_SOCKET" ]; do
  i=$((i + 1))
  if [ "$i" -gt 600 ]; then
    echo "rustcfml: engine did not create $PROXY_SOCKET within 60s; not starting nginx" >&2
    shutdown
    exit 69
  fi
  if ! kill -0 "$engine_pid" 2>/dev/null; then
    echo "rustcfml: engine exited before it could serve" >&2
    wait "$engine_pid" || exit $?
    exit 69
  fi
  sleep 0.1
done

nginx -c "$CONF" -g 'daemon off;' &
nginx_pid=$!

# Wake as soon as EITHER exits, then take the other down and let the platform
# restart the container.
wait -n 2>/dev/null || true
shutdown
wait
