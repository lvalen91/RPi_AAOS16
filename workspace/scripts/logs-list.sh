#!/usr/bin/env bash
# logs-list.sh — show every log with size, mtime, and parsed
# start/end markers (if the run finished).

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

shopt -s nullglob
LOGS=( "$AAOS_LOGS"/*.log )
shopt -u nullglob

if [ "${#LOGS[@]}" -eq 0 ]; then
  echo "No logs yet in $AAOS_LOGS"
  exit 0
fi

printf '%-22s %7s  %-24s  %s\n' "FILE" "SIZE" "MTIME" "STATUS"
printf '%s\n' "-----------------------------------------------------------------------------"

# newest first
# shellcheck disable=SC2012
ls -1t "$AAOS_LOGS"/*.log 2>/dev/null | while read -r f; do
  [ -L "$f" ] && continue  # skip the latest-*.log symlinks
  base=$(basename "$f")
  size=$(du -h "$f" | awk '{print $1}')
  mtime=$(date -r "$f" '+%Y-%m-%dT%H:%M:%S')
  # Look for "==== <tag>: end ... exit=N ====" marker
  if grep -q '==== .*: end .* exit=' "$f" 2>/dev/null; then
    rc=$(grep '==== .*: end .* exit=' "$f" | tail -1 | sed -E 's/.*exit=([0-9]+).*/\1/')
    if [ "$rc" = "0" ]; then
      status="${C_GRN}done (exit=0)${C_OFF}"
    else
      status="${C_RED}failed (exit=$rc)${C_OFF}"
    fi
  else
    status="${C_YLW}running / incomplete${C_OFF}"
  fi
  printf '%-22s %7s  %-24s  ' "$base" "$size" "$mtime"
  printf '%b\n' "$status"
done

echo
say "Tail latest with: ./scripts/logs-tail.sh            (any)"
say "                  ./scripts/logs-tail.sh sync-aosp  (by tag)"
