# RustCFML Docker image

The reference container image for [RustCFML](https://github.com/RustCFML/RustCFML),
a CFML engine written in Rust.

```
ghcr.io/rustcfml/rustcfml:<tag>
```

Multi-arch (`linux/amd64`, `linux/arm64`), ~36 MB, runs as a non-root user,
stops cleanly on `docker stop`, and checks for native extensions (`.rcx`)
before the server starts.

## Run an app

```sh
docker run --rm -p 8500:8500 -v "$PWD/webroot:/app" ghcr.io/rustcfml/rustcfml
```

Open http://localhost:8500. The webroot is `/app`; the default mode is
`production` (everything is cached until restart). For local development, where
edits should show up without a restart:

```sh
docker run --rm -p 8500:8500 -v "$PWD/webroot:/app" -e RUSTCFML_MODE=dev ghcr.io/rustcfml/rustcfml
```

Or with compose, see [`docker-compose.yml`](docker-compose.yml): `docker compose up`.

## Use it as a base image

```dockerfile
FROM ghcr.io/rustcfml/rustcfml:v0.653.3
COPY --chown=nonroot:nonroot webroot/ /app/
```

If the app ships native extensions in `/app/extensions/`, warm them at build
time so the first container start does not pay for extracting them, and so a
broken or wrong-platform archive fails the *build* rather than the deploy:

```dockerfile
RUN rustcfml-warm-extensions
```

Anything the app needs at the OS level is an `apk add` away (the base is
Chainguard Wolfi): fonts for PDF rendering, `nginx` to terminate TLS, and so on.
Switch to `USER root` for the install and back to `USER nonroot` afterwards.

## Other commands

The first argument decides what runs. A flag (or nothing) serves; anything else
is passed to the engine as-is:

```sh
docker run --rm -v "$PWD:/app" ghcr.io/rustcfml/rustcfml script.cfm      # run a CFML file
docker run --rm -v "$PWD:/app" ghcr.io/rustcfml/rustcfml ext list        # installed extensions
docker run --rm ghcr.io/rustcfml/rustcfml --version
docker run --rm ghcr.io/rustcfml/rustcfml --licenses
docker run --rm -p 8500:8500 -v "$PWD:/app" ghcr.io/rustcfml/rustcfml --verbose   # serve, extra flag
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `RUSTCFML_MODE` | `production` | `production` caches Application.cfc resolution, URL→file resolution and bytecode until restart; `dev` re-checks on every request |
| `RUSTCFML_WEBROOT` | `/app` | Directory to serve |
| `RUSTCFML_PORT` | `8500` | TCP port |
| `RUSTCFML_SOCKET` | unset | Bind a Unix socket at this path instead of a TCP port (for a proxy in a *separate* container). Must be a path the `nonroot` user can create, e.g. `/tmp/rustcfml.sock`. Cannot be combined with `RUSTCFML_PROXY=nginx` |
| `RUSTCFML_PROXY` | `none` | `nginx` runs nginx in front of the engine inside this container, reaching it over a Unix socket. See [Fronting with nginx](#fronting-with-nginx) |
| `RUSTCFML_MAX_MEMORY` | `auto` | Process memory limit: `auto` (75% of the cgroup limit), or an explicit `1.5G` / `1536M`; empty to disable. Above 85% new requests get 503 + Retry-After while the process sheds; above 95% the in-flight request that has allocated the most is aborted, so one runaway cannot OOM the container |
| `RUSTCFML_EXTENSIONS` | unset | Extra `.rcx` directory, searched first |
| `RUSTCFML_EXTENSIONS_STRICT` | `1` | Refuse to start if any extension fails to load (exit 78). `0` logs and continues |
| `RUSTCFML_SINGLE_THREADED` | unset | `1` for a single-threaded runtime (lower memory, lower concurrency) |
| `RUSTCFML_HEALTHCHECK_PATH` | unset | Path the `HEALTHCHECK` must get a 2xx/3xx from. Unset, any HTTP answer on the port counts |
| `CFCONFIG` | unset | Explicit server-level `.cfconfig.json`. Without it the engine looks in the webroot, then the working directory, then beside the binary |

Datasources, mappings, logging and other engine settings go in a
[`.cfconfig.json`](https://github.com/RustCFML/RustCFML/blob/main/docs/configuration.md)
in the webroot. Application-level files beside an `Application.cfc` overlay the
server baseline.

## Fronting with nginx

```bash
docker run -e RUSTCFML_PROXY=nginx -p 8500:8500 -v "$PWD:/app" ghcr.io/rustcfml/rustcfml
```

nginx takes the published port and reaches the engine over a Unix socket at
`/run/rustcfml.sock`, so requests never cross the loopback TCP stack: no
three-way handshake per connection, no `TIME_WAIT` accumulation, no ephemeral
port exhaustion under load. It also buffers slow clients, which keeps a request
from occupying an engine thread while a phone on a train uploads a form.

Both processes run in this container, supervised by the entrypoint: if either
exits the other is stopped and the container exits, so your orchestrator
restarts a whole, healthy unit rather than a half-dead one. On a stop signal
nginx is drained with `SIGQUIT` and the engine with `SIGTERM`, so in-flight
requests finish.

It is **off by default** — with `RUSTCFML_PROXY=none` the engine binds the port
itself and is PID 1, exactly as before. nginx is installed either way: it costs
**4 MB** on a 153 MB image, which is not worth a second published variant and a
"which tag do I want?" question on every deployment.

The proxy passes `Host`, `X-Real-IP`, `X-Forwarded-For` and `X-Forwarded-Proto`
(preserving an upstream terminator's value), and passes WebSocket upgrades
through. To change anything else — serving static assets straight from nginx is
the obvious one — mount your own config over `/etc/nginx/nginx.conf`. It is a
template: `__PORT__` and `__SOCKET__` are substituted at startup.

**When not to use it.** If your platform already has a proxy in front (an
ingress controller, an ALB, Fly's edge), a second one inside the container adds
a hop for little gain — use `RUSTCFML_PROXY=none`. If you want nginx in its own
container, use `RUSTCFML_SOCKET` with a shared volume instead.

## Native extensions

RustCFML loads precompiled Rust extensions (`.rcx`) once, at process start,
from these locations in order, first hit per name:

1. `RUSTCFML_EXTENSIONS` (`--extensions`)
2. `extensions.directory` in the server `.cfconfig.json`
3. `/app/extensions/` (the webroot) — the usual place, checked into the app
4. `/home/nonroot/.rustcfml/extensions/`
5. `/opt/rustcfml/extensions/` — beside the binary, for extensions baked into a derived image

On first load the archive's library for this platform is extracted to
`/home/nonroot/.rustcfml/ext-cache/<sha256>/`. Both the entrypoint and the
`rustcfml-warm-extensions` command run that load once, print what was found,
and stop with a message if an archive is corrupt, built for another platform or
another engine ABI:

```
rustcfml: extensions — 1 .rcx found, 1 loaded, 0 problem(s)
  Loaded extension pdf 0.3.0 (14 bif(s), 2 class(es), 0 sql fn(s)) from /app/extensions/pdf-0.3.0.rcx
```

A published extension ships one archive per platform; for this image take the
`linux-x86_64` and `linux-aarch64` ones (a single `.rcx` can carry both, in
which case one file serves both architectures of the image). See
[docs/extensions.md](https://github.com/RustCFML/RustCFML/blob/main/docs/extensions.md).

## What is in the image

| | |
|---|---|
| Base | `cgr.dev/chainguard/wolfi-base` (glibc, apk, busybox shell) + `tzdata`, `curl`, `ca-certificates` |
| Engine | The PGO-built binary from the matching [RustCFML GitHub release](https://github.com/RustCFML/RustCFML/releases), at `/opt/rustcfml/rustcfml` and on `PATH` |
| Notices | `/opt/rustcfml/LICENSE`, `/opt/rustcfml/THIRD-PARTY.txt`, `/opt/rustcfml/VERSION`; also `rustcfml --licenses` |
| User | `nonroot` (uid 65532). `/app`, `/opt/rustcfml/extensions` and `/home/nonroot` are writable by it |
| Signals | From v0.653.14 the engine drains in-flight requests and exits on SIGTERM or SIGINT, so `docker stop` returns as soon as the last request finishes. `STOPSIGNAL SIGINT` is kept only so that pinning an older engine (which ignored SIGTERM as PID 1, costing a 10 s wait then SIGKILL) still stops cleanly |
| Health | `HEALTHCHECK` every 30 s against the port (see `RUSTCFML_HEALTHCHECK_PATH`); skipped in socket mode |
| Logs | Engine output on stdout/stderr. `<cflog>`/`writeLog()` files go to `/app/logs/` unless `logging.logsDirectory` is set in `.cfconfig.json` |
| Smoke | Every build runs the engine inside the runtime image on each platform and refuses to publish if it does not (`/opt/rustcfml/smoke.txt`) |

Nothing is compiled in this repository. The Dockerfile downloads the release
binary for each target platform, so a two-platform build takes seconds and
needs no cross-compilation; the only emulated steps are the version check and
the smoke test.

## Tags

| Tag | Meaning |
|---|---|
| `v0.653.3` | that engine release. Rebuilt in place if the image itself changes |
| `v0.653.3-2` | engine release + image build number; immutable |
| `0.653` | latest image for that minor series |
| `latest` | latest tagged release |
| `edge` | last push to `main` |

## Releasing a new engine version

1. Bump `ARG RUSTCFML_VERSION` in the `Dockerfile` to the new release tag.
2. Commit, tag `v<version>` (or `v<version>-<n>` for an image-only change), push the tag.

CI refuses a tag whose version does not match the Dockerfile. The
`workflow_dispatch` form also takes an engine version, pushed as `edge`, to
try a release before tagging.

## Building locally

```sh
make build              # native arch -> rustcfml:local
make smoke              # version, ext list, serve + request, SIGINT stop, broken-extension handling
make build-all          # both platforms, proves the multi-arch build
make run                # serve examples/hello on :8500
```

`tests/smoke.sh` also takes `SMOKE_RCX=/path/to/ext.rcx` to check a real
extension for this platform loads and its functions are callable.

## Licence

MIT, as is the engine. The image also carries the engine's third-party notices
(`/opt/rustcfml/THIRD-PARTY.txt`).
