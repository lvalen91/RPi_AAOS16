#!/usr/bin/env bash
# Drop into an interactive shell inside the AAOS builder VM.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
exec limactl shell "$VM_NAME" "$@"
