#!/bin/sh
# Print the webroot to serve, on stdout. Any advisory goes to stderr, so
#   WEBROOT="$(rustcfml-webroot)"
# is always just the path.
#
# The default moved from /app to /srv/app in the v0.685.5-2 image. /app is the
# obvious name for a container webroot, but it is also the name ColdBox gives
# its application mapping by default (`appMapping`, which Preside inherits), and
# the engine resolves a CFML mapping prefix before it looks at the filesystem.
# With the webroot at /app and that mapping registered, a real path like
#   /app/preside/system/views
# resolves through the mapping to /app/application/preside/system/views instead,
# so directoryExists() answers false for a directory that is plainly there.
# ColdBox's own bootstrap trips on this and dies with the memorable
#   "ViewsExternalLocation could not be found."
# Nothing in the message points at the webroot, which is what made it worth
# moving the default rather than documenting a trap.
#
# Images and compose files that mount to /app keep working: if /app has content
# and /srv/app does not, /app is used and the reason is printed once.
set -eu

has_content() {
	[ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

if [ -n "${RUSTCFML_WEBROOT:-}" ]; then
	printf '%s\n' "$RUSTCFML_WEBROOT"
	exit 0
fi

if has_content /srv/app; then
	printf '%s\n' /srv/app
	exit 0
fi

if has_content /app; then
	echo "rustcfml: serving /app — the default webroot is now /srv/app." >&2
	echo "  /app works, but it collides with ColdBox's default appMapping of \"/app\":" >&2
	echo "  a CFML mapping of that name shadows the real directory in path lookups," >&2
	echo "  which surfaces as \"ViewsExternalLocation could not be found.\" on ColdBox" >&2
	echo "  and Preside. Mount at /srv/app, or set RUSTCFML_WEBROOT to silence this." >&2
	printf '%s\n' /app
	exit 0
fi

# Neither exists: fall through to the default so the caller reports the miss
# against the path people should be mounting to.
printf '%s\n' /srv/app
