#!/bin/sh
# Pre-compile the webroot into the persistent bytecode cache, at image build time.
#
# The engine compiles each template on its first hit after a process start. With
# a cache directory it writes the compiled bytecode there and reloads it on the
# next start; filling that directory when the image is built takes compilation
# out of container start-up and off the first request to every page.
#
#   FROM ghcr.io/rustcfml/rustcfml
#   COPY --chown=nonroot:nonroot webroot/ /srv/app/
#   RUN rustcfml-warm-bytecode
#
# The entrypoint then serves with the same cache directory, so the entries are
# found. Nothing else is needed: the default directory is under $HOME, which the
# image fixes, so the warmed layer and the running server see the same path.
#
#   RUSTCFML_BYTECODE_CACHE   /home/nonroot/.rustcfml/bytecode-cache
#                             (empty disables the cache; this script then does nothing)
#   RUSTCFML_WEBROOT          /srv/app (see rustcfml-webroot)
#
# An entry is keyed by the source content AND the docroot path as the engine
# spelled it, so this script resolves the webroot exactly as the entrypoint does
# and runs from the same directory: `--warm X` here matches `--serve X` there,
# character for character. A relative RUSTCFML_WEBROOT works, as long as it is
# the same relative path at start.
#
# A template that does not compile is reported but not fatal: it fails the same
# way at request time whether or not it was warmed, and a tree that ships a
# deliberately broken fixture must not fail the image build. A webroot with no
# CFML in it at all, or none that compiles, IS fatal (the engine exits 1): that
# is a COPY that landed in the wrong place, and the build should say so.
#
# The cache directory is code: anything that can write to it runs CFML in the
# server. It is owned by the `nonroot` user the server runs as; keep it that way.
set -eu

CACHE="${RUSTCFML_BYTECODE_CACHE-/home/nonroot/.rustcfml/bytecode-cache}"
if [ -z "$CACHE" ]; then
  echo "rustcfml: bytecode cache disabled (RUSTCFML_BYTECODE_CACHE is empty); nothing to warm"
  exit 0
fi

# Engines before v0.743.0 have no persistent cache. Say so and succeed, so a
# derived Dockerfile that warms is still buildable against a pinned older engine.
if ! rustcfml --help 2>/dev/null | grep -q -- '--bytecode-cache'; then
  echo "rustcfml: this engine ($(rustcfml --version 2>/dev/null || echo unknown)) has no --bytecode-cache; nothing warmed" >&2
  exit 0
fi

WEBROOT="$(/usr/local/bin/rustcfml-webroot)"
if [ ! -d "$WEBROOT" ]; then
  echo "rustcfml: webroot '$WEBROOT' does not exist (COPY your app to $WEBROOT or set RUSTCFML_WEBROOT)" >&2
  exit 64
fi

cd "$WEBROOT"
exec rustcfml --warm "$WEBROOT" --bytecode-cache "$CACHE"
