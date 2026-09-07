# syntax=docker/dockerfile:1.7
#
# RustCFML — reference container image.
#
#   docker run --rm -p 8500:8500 -v "$PWD/webroot:/app" ghcr.io/rustcfml/rustcfml
#
# or as a base image for an application:
#
#   FROM ghcr.io/rustcfml/rustcfml:v0.653.3
#   COPY webroot/ /app/
#   RUN rustcfml-warm-extensions      # only if /app/extensions/ holds .rcx files
#
# Multi-arch (linux/amd64, linux/arm64). Nothing is compiled here: each
# platform's stage downloads the matching PGO'd binary from the RustCFML GitHub
# release, so a multi-platform build takes seconds and needs no QEMU-hours.
#
# Layout inside the image
#   /opt/rustcfml/rustcfml          the engine (also on PATH as `rustcfml`)
#   /opt/rustcfml/extensions/       image-level .rcx extensions (search location 5)
#   /opt/rustcfml/LICENSE, THIRD-PARTY.txt, VERSION
#   /app                            the webroot (search location 3 is /app/extensions/)
#   /home/nonroot/.rustcfml/        per-user extensions/ and the ext-cache/ the
#                                   loader extracts libraries into
#
# See README.md for every environment variable the entrypoint understands.

# The engine version this image packages, and the single source of truth for it:
# CI refuses a git tag that disagrees with this line, and the "Follow the
# engine's stable release" workflow bumps it when a new engine build is promoted
# to stable. Override for a one-off build with
# --build-arg RUSTCFML_VERSION=vX.Y.Z.
#
# Graceful shutdown on SIGTERM needs >= v0.653.14 (see STOPSIGNAL below).
ARG RUSTCFML_VERSION=v0.653.14

# ---------------------------------------------------------------------------
# Stage 1: fetch the release binary for the TARGET platform, running on the
# BUILD platform (so curl is never emulated). TARGETARCH is set by buildx.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM cgr.dev/chainguard/wolfi-base:latest AS fetch
ARG RUSTCFML_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl
RUN case "${TARGETARCH}" in \
        amd64) ASSET=rustcfml-linux-x86_64 ;; \
        arm64) ASSET=rustcfml-linux-aarch64 ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (amd64, arm64)"; exit 1 ;; \
    esac \
    && BASE="https://github.com/RustCFML/RustCFML/releases/download/${RUSTCFML_VERSION}" \
    && mkdir -p /out \
    && curl -fsSL -o /out/rustcfml        "${BASE}/${ASSET}" \
    && curl -fsSL -o /out/LICENSE         "${BASE}/LICENSE" \
    && curl -fsSL -o /out/THIRD-PARTY.txt "${BASE}/THIRD-PARTY.txt" \
    && chmod 0755 /out/rustcfml \
    && echo "${RUSTCFML_VERSION}" > /out/VERSION

# ---------------------------------------------------------------------------
# Stage 2: runtime. Chainguard Wolfi base: ~6 MB, glibc (the release binary
# is glibc-linked and needs >= 2.39, which rules out debian:bookworm), apk and
# a busybox shell so derived images can install fonts, nginx, etc.
# ---------------------------------------------------------------------------
FROM cgr.dev/chainguard/wolfi-base:latest AS runtime

# tzdata: dateFormat/timezone BIFs need zoneinfo. curl: the HEALTHCHECK, and
# handy in derived images. ca-certificates is already in the base (TLS to
# databases, cfhttp, S3).
# nginx is installed but NOT started unless RUSTCFML_PROXY=nginx. One image
# rather than two published variants: nginx and its dependencies measure +4 MB on a
# 153 MB image (157 MB with), so a separate slim tag would save nothing worth the
# split build, the second thing to promote, and the "which tag do I want?"
# question for every user.
RUN apk add --no-cache tzdata curl nginx \
    && mkdir -p /var/lib/nginx/tmp/client_body /var/lib/nginx/tmp/proxy

COPY --from=fetch /out/rustcfml /out/LICENSE /out/THIRD-PARTY.txt /out/VERSION /opt/rustcfml/
COPY docker/entrypoint.sh            /usr/local/bin/rustcfml-entrypoint
COPY docker/warm-extensions.sh       /usr/local/bin/rustcfml-warm-extensions
COPY docker/healthcheck.sh           /usr/local/bin/rustcfml-healthcheck
COPY docker/nginx.conf               /etc/nginx/nginx.conf

# /app is the webroot. /opt/rustcfml/extensions is the image-level extension
# directory (searched last). Both, plus the nonroot home (where the loader's
# ext-cache lives), are owned by the runtime user so extensions can be warmed
# and logs written without root.
RUN ln -s /opt/rustcfml/rustcfml /usr/local/bin/rustcfml \
    && chmod 0755 /usr/local/bin/rustcfml-entrypoint /usr/local/bin/rustcfml-warm-extensions /usr/local/bin/rustcfml-healthcheck \
    && mkdir -p /app /opt/rustcfml/extensions /home/nonroot/.rustcfml/extensions /home/nonroot/.rustcfml/ext-cache \
    && chown -R nonroot:nonroot /app /opt/rustcfml/extensions /home/nonroot \
    && chown -R nonroot:nonroot /var/lib/nginx /run \
    && rustcfml --version

USER nonroot
# HOME must be fixed and writable: the extension loader extracts each .rcx's
# library into $HOME/.rustcfml/ext-cache/<sha256>/ on first load. Warming at
# image build time (rustcfml-warm-extensions) only helps if the runtime sees the
# same HOME.
# RUSTCFML_MAX_MEMORY=auto gives the process a ceiling of 75% of the container's
# cgroup limit, so `docker run -m 2g` is enough to get back-pressure (503 above
# 85% of it) and the runaway-request abort (above 95%) with no other
# configuration. It reads the cgroup limit at startup and installs no limit at
# all when there is none, so it is safe in an unconstrained container too.
# Set it to an explicit size to override, or to an empty string to disable.
ENV HOME=/home/nonroot \
    RUSTCFML_MODE=production \
    RUSTCFML_WEBROOT=/app \
    RUSTCFML_PORT=8500 \
    RUSTCFML_MAX_MEMORY=auto \
    RUSTCFML_PROXY=none

WORKDIR /app
EXPOSE 8500

# Kept for engines older than v0.653.14, which handled only SIGINT. As PID 1 the
# kernel installs no default signal dispositions, so an unhandled SIGTERM —
# docker's default stop signal — was IGNORED, turning every `docker stop` into a
# 10 s wait followed by SIGKILL. From v0.653.14 the engine drains and exits on
# either signal, so this line is belt-and-braces; it stays so that pinning an
# older RUSTCFML_VERSION still stops cleanly.
STOPSIGNAL SIGINT

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/rustcfml-healthcheck"]

ENTRYPOINT ["/usr/local/bin/rustcfml-entrypoint"]

# ---------------------------------------------------------------------------
# Stage 3: smoke test. Runs the engine inside the runtime image on this
# platform (under QEMU for the non-native one), exercises the extension probe
# with no extensions present, and copies a marker into the final stage so the
# build cannot succeed without it.
# ---------------------------------------------------------------------------
FROM runtime AS smoke
COPY --chown=nonroot:nonroot examples/hello/webroot /smoke/webroot
RUN cd /smoke/webroot \
    && rustcfml index.cfm | tee /tmp/smoke.log \
    && grep -q "RustCFML" /tmp/smoke.log \
    && RUSTCFML_WEBROOT=/smoke/webroot rustcfml-warm-extensions \
    && printf 'engine %s\n' "$(rustcfml --version)" > /tmp/smoke.ok

FROM runtime
COPY --from=smoke /tmp/smoke.ok /opt/rustcfml/smoke.txt
