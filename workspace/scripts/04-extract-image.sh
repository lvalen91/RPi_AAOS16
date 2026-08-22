#!/usr/bin/env bash
# 04-extract-image.sh pi4|pi5 — copy the freshly built flashable image
# from the VM's AOSP out/ directory to the host-shared /mnt/out, which
# appears on macOS as $AAOS_ROOT/out/.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

TARGET="${1:-}"
case "$TARGET" in
  pi4|pi5) ;;
  *) die "Usage: $0 pi4|pi5" ;;
esac
start_log "extract-${TARGET}"

vm_push_scripts
vm_run extract-image.sh "$TARGET"
say "images now in $AAOS_OUT:"
ls -lh "$AAOS_OUT/" || true
