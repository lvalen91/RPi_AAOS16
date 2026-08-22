#!/usr/bin/env bash
# DESTRUCTIVE: delete the AAOS builder VM and everything inside it
# (including the AOSP source tree and all built artifacts inside the VM).
# Host-side files under $AAOS_OUT are NOT touched.

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

cat <<EOF
${C_RED}WARNING${C_OFF}: This will permanently delete VM '$VM_NAME' and ALL
files inside it, including the full AOSP source tree (~150 GB) and
any in-progress builds. Host-side images under $AAOS_OUT stay put.
EOF
read -rp "Type 'DESTROY' to confirm: " ans
[ "$ans" = "DESTROY" ] || { echo "Aborted."; exit 0; }

limactl stop "$VM_NAME" 2>/dev/null || true
limactl delete "$VM_NAME"
ok "VM deleted."
