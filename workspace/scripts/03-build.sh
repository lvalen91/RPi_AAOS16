#!/usr/bin/env bash
# 03-build.sh pi4|pi5 — build AAOS inside the VM for the given board.
#
# Lunch target: aosp_rpi{4,5}_car-bp4a-userdebug (automotive, Android 16 QPR2).
# Uses the full VM CPU count; make sure other heavy work isn't running.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prevent macOS from sleeping mid-build — HVF+QEMU can wedge on sleep/wake.
# Re-exec self under caffeinate(1) so the whole build stays awake, including
# idle, display, and system-sleep timers. See docs/build-tuning-2026-04-13.md.
if [ -z "${_AAOS_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  export _AAOS_CAFFEINATED=1
  exec caffeinate -dims "$0" "$@"
fi

# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

TARGET="${1:-}"
case "$TARGET" in
  pi4|pi5) ;;
  *) die "Usage: $0 pi4|pi5" ;;
esac
start_log "build-${TARGET}"

limactl list -q 2>/dev/null | grep -qx "$VM_NAME" || die "VM '$VM_NAME' not found."
vm_push_scripts
say "building AAOS for $TARGET inside VM…"
say "(first build: ~2-3h on this host; incremental builds cached by ccache)"
vm_run build-aaos.sh "$TARGET"
ok "$TARGET build complete. Run: ./04-extract-image.sh $TARGET"
