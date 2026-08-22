#!/usr/bin/env bash
# Show AAOS builder VM status.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
if limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  limactl list "$VM_NAME"
else
  echo "VM '$VM_NAME' has not been created yet. Run ./01-create-vm.sh"
fi
