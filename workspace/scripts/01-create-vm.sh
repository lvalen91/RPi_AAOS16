#!/usr/bin/env bash
# 01-create-vm.sh — create (or start) the AAOS builder Lima VM.
#
# Idempotent: if the VM already exists it's just started. The VM state
# lives in $LIMA_HOME (/Volumes/stuff/virtual-machines/lima, set by
# env.sh). Provisioning installs all AOSP prereqs automatically.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
start_log create-vm

if limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  say "VM '$VM_NAME' already exists; starting it…"
  limactl start "$VM_NAME"
else
  say "creating VM '$VM_NAME' from $AAOS_TEMPLATE"
  # --tty=false keeps Lima from asking interactive questions so this
  # script is safe to run unattended.
  limactl start --tty=false --name="$VM_NAME" "$AAOS_TEMPLATE"
fi

limactl list "$VM_NAME"

# Sanity check: provisioning succeeded.
if limactl shell "$VM_NAME" -- command -v repo >/dev/null 2>&1; then
  ok "repo tool present inside VM"
else
  warn "repo tool NOT yet present — provisioning may still be running."
  warn "Check: limactl shell $VM_NAME sudo cloud-init status --long"
fi

say "VM is up. Next: ./02-sync-aosp.sh"
