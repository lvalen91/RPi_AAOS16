#!/usr/bin/env bash
# logs-tail.sh [tag]
#
# Live-tail the most recent log for a given tag (e.g. sync-aosp,
# build-pi4, build-pi5, extract-pi4, create-vm). With no arg, tails
# the most recent log of any kind.
#
# Safe to run from a second terminal while a build is in progress —
# it just follows the log file that the main script is writing to.

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

TAG="${1:-}"
if [ -n "$TAG" ]; then
  SYM="$AAOS_LOGS/latest-${TAG}.log"
else
  SYM="$AAOS_LOGS/latest.log"
fi

if [ ! -L "$SYM" ] && [ ! -f "$SYM" ]; then
  echo "No log yet for tag='${TAG:-(any)}'." >&2
  echo "Available logs:" >&2
  ls -1t "$AAOS_LOGS"/*.log 2>/dev/null | head -10 >&2 || echo "  (none)" >&2
  exit 1
fi

TARGET="$(readlink "$SYM" 2>/dev/null || echo "")"
say "tailing: $SYM${TARGET:+  →  $TARGET}"
echo "(Ctrl-C to stop — this does not affect the build.)"
echo
exec tail -n 200 -F "$SYM"
