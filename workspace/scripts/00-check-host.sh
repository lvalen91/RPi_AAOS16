#!/usr/bin/env bash
# 00-check-host.sh — verify the macOS host is ready to run the Lima VM.
#
# Exits non-zero if anything critical is missing. Run this before
# 01-create-vm.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

say "AAOS host readiness check"

# --- macOS + architecture ---
case "$(uname -s)" in
  Darwin) ok "host OS: macOS ($(sw_vers -productVersion 2>/dev/null || uname -r))" ;;
  *)      die "not macOS: $(uname -s)" ;;
esac
ARCH="$(uname -m)"
ok "host arch: $ARCH"
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "arm64" ]; then
  die "unsupported arch: $ARCH"
fi
if [ "$ARCH" = "x86_64" ]; then
  warn "Intel host → Lima must use QEMU (vmType: qemu). Apple Silicon would allow vz."
fi

# --- Lima ---
command -v limactl >/dev/null || die "limactl not installed. Try: brew install lima"
ok "limactl: $(limactl --version)"

# --- CPU / RAM ---
PHYS_CPUS=$(sysctl -n hw.physicalcpu)
LOG_CPUS=$(sysctl -n hw.ncpu)
MEM_BYTES=$(sysctl -n hw.memsize)
MEM_GIB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
say "host: $PHYS_CPUS physical / $LOG_CPUS logical cores, ${MEM_GIB} GiB RAM"
[ "$PHYS_CPUS" -ge 8 ] || die "need ≥8 physical cores (have $PHYS_CPUS)"
[ "$MEM_GIB"   -ge 32 ] || die "need ≥32 GiB RAM (have ${MEM_GIB} GiB)"

# --- Disk space on the project volume ---
VOL_INFO=$(df -g "$AAOS_ROOT" | awk 'NR==2')
AVAIL_GIB=$(echo "$VOL_INFO" | awk '{print $4}')
MOUNT=$(echo "$VOL_INFO" | awk '{print $NF}')
say "volume $MOUNT has ${AVAIL_GIB} GiB available"
[ "$AVAIL_GIB" -ge 700 ] || die "need ≥700 GiB free on $MOUNT (have ${AVAIL_GIB} GiB)"

# --- Project files ---
[ -f "$AAOS_TEMPLATE" ] || die "Lima template missing: $AAOS_TEMPLATE"
ok "lima template: $AAOS_TEMPLATE"
ok "LIMA_HOME:     $LIMA_HOME"
ok "output dir:    $AAOS_OUT"

say "all checks passed. Next: ./01-create-vm.sh"
