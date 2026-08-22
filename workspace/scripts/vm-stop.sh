#!/usr/bin/env bash
# Gracefully stop the AAOS builder VM (state preserved in $LIMA_HOME).
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
limactl stop "$VM_NAME"
