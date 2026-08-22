#!/usr/bin/env bash
# 02-sync-aosp.sh — invoke the in-VM repo init + sync.
#
# Runs /mnt/scripts/sync-aosp.sh inside the VM. Expects the VM to be
# running; if not, start it with 01-create-vm.sh first.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
start_log sync-aosp

limactl list -q 2>/dev/null | grep -qx "$VM_NAME" || die "VM '$VM_NAME' does not exist. Run 01-create-vm.sh first."
vm_push_scripts
say "syncing AOSP android-16.0.0_r4 + raspberry-vanilla inside VM…"
say "(this will download ~100-150 GB; expect 1-3 hours)"
vm_run sync-aosp.sh "$@"
ok "sync complete. Next: ./03-build.sh pi4  (or pi5)"
