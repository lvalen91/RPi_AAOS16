#!/usr/bin/env bash
# patches/apply.sh <aosp-tree> — apply the Pi 4 platform patches to a synced AOSP tree.
#
# Idempotent: a patch that is already applied is skipped, not re-applied.
#
# These are AOSP-project patches, one directory per repo project. They are kept
# as files rather than as branches in the tree because `repo sync --force-sync`
# detaches local branches, and because a 300 GB repo checkout is not a
# distribution mechanism — this is what lets someone else rebuild the image.
#
# The kernel is NOT patched here. It is a separate out-of-tree build; see
# build_kernel_rpi4.sh, which applies patches/kernel_brcm_rpi/ itself.
set -euo pipefail

AOSP="${1:-}"
[ -n "$AOSP" ] || { echo "usage: $0 <aosp-tree>" >&2; exit 1; }
[ -d "$AOSP/.repo" ] || { echo "not an AOSP tree: $AOSP" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# patch directory name -> project path in the AOSP tree
declare -A PROJECTS=(
  [device_brcm_rpi4]="device/brcm/rpi4"
  [hardware_interfaces]="hardware/interfaces"
  [external_ffmpeg_codec2]="external/ffmpeg_codec2"
)

rc=0
for dir in "${!PROJECTS[@]}"; do
  proj="${PROJECTS[$dir]}"
  [ -d "$SCRIPT_DIR/$dir" ] || continue
  if [ ! -d "$AOSP/$proj" ]; then
    echo "SKIP  $proj (not in tree)"; continue
  fi
  for p in "$SCRIPT_DIR/$dir"/*.patch; do
    [ -e "$p" ] || continue
    name="$(basename "$p")"
    if git -C "$AOSP/$proj" apply --reverse --check "$p" >/dev/null 2>&1; then
      echo "OK    $proj: $name (already applied)"
      continue
    fi
    if git -C "$AOSP/$proj" apply --check "$p" >/dev/null 2>&1; then
      git -C "$AOSP/$proj" apply "$p"
      echo "APPLY $proj: $name"
    else
      echo "FAIL  $proj: $name does not apply cleanly" >&2
      rc=1
    fi
  done
done

exit $rc
