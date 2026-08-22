#!/usr/bin/env bash
# vm/apply-customizations.sh pi4|pi5 — runs INSIDE the Lima VM.
#
# Idempotent modifications to the raspberry-vanilla device tree before
# building, driven by $TARGET. Covers:
#
#   1. UART serial console — ttyS0, and miniuart-bt forced OFF (2026-08-16)
#   2. Ethernet + root shell over adbd-tcp (our "SSH on RJ45" MVP)
#   3. SELinux permissive (already set by default)
#   4. Drops in any *.rc files from /mnt/overlays/init
#   5. Force CPU governor = performance via kernel cmdline
#   6. Include DocumentsUI (the Files app) in PRODUCT_PACKAGES
#
# Every modification is idempotent — safe to rerun before every build.
#
# If dropbear SSH is ever wired up as a real AOSP project via
# /mnt/overlays/local_manifests/*.xml, this script is the place to
# enable its service.

set -euo pipefail

TARGET="${1:-}"
# Accept either short (pi4/pi5) or canonical (rpi4/rpi5) form; canonicalize
# to $BOARD which is what the AOSP device tree and lunch target actually use.
case "$TARGET" in
  pi4|rpi4) BOARD=rpi4 ;;
  pi5|rpi5) BOARD=rpi5 ;;
  *) echo "Usage: $0 pi4|pi5   (or rpi4|rpi5)" >&2; exit 1 ;;
esac

AOSP_DIR="$HOME/aosp"
DEV_DIR="$AOSP_DIR/device/brcm/$BOARD"
[ -d "$DEV_DIR" ] || { echo "device tree missing: $DEV_DIR"; exit 1; }

echo "[customize] target=$TARGET  board=$BOARD  device-tree=$DEV_DIR"

# ---------------------------------------------------------------------
# 1. UART / serial console
# ---------------------------------------------------------------------
# Pi 4 and Pi 5 have DIFFERENT UART layouts; raspberry-vanilla already
# sets the correct cmdline. We only guarantee config.txt has the right
# bits and leave BOARD_KERNEL_CMDLINE alone.
#
#   Pi 4:  console=ttyS0,115200         (mini UART on GPIO 14/15)
#   Pi 5:  console=ttyAMA10,115200      (dedicated 3-pin JST SH debug)
# ---------------------------------------------------------------------
CFG="$DEV_DIR/boot/config.txt"
if [ -f "$CFG" ]; then
  case "$BOARD" in
    rpi4)
      # Pi 4: ensure enable_uart=1 (it is, by default).
      if ! grep -q '^enable_uart=1' "$CFG"; then
        echo '[customize] adding enable_uart=1 to boot/config.txt'
        printf '\n# Serial console on GPIO 14 (TX) / GPIO 15 (RX), 115200 8N1 — ttyS0\nenable_uart=1\n' >> "$CFG"
      fi
      # Pi 4 UART: `dtoverlay=miniuart-bt` must stay OFF. RETRACTION of the
      # 2026-04-13/14 conclusion below — hardware testing on 2026-08-16
      # (Pi 4 Rev 1.5, AAOS 16 build 20260413) showed the paired change is
      # not just unnecessary, it is actively harmful, and this script is
      # what kept re-applying it.
      #
      # What the overlay actually does: it leaves a `bluetooth` node on
      # BOTH UARTs. hci_uart_bcm is a *serdev* driver bound through device
      # tree, not through a tty node, so it binds serial0-0 — the PL011
      # the overlay has just routed to GPIO 14/15. The kernel then speaks
      # HCI out the debug pins while the console is wired to the BT chip.
      # Symptoms: a silent UART, `Frame reassembly failed (-84)`,
      # `command 0xfc18 tx timeout`, `hardware error 0x10`, and
      # com.android.bluetooth crash-looping.
      #
      # The 2026-04-14 "verified" note claimed `hci0 -> fe215040.serial`
      # and `[ttyAMA0] enabled` simultaneously. Whatever was observed, BT
      # did not survive it on real hardware four months later; treat that
      # note as superseded rather than as a second data point.
      #
      # Correct configuration: NO overlay, console stays on ttyS0. BT then
      # sits on the PL011 (BCM4345C0.hcd patchram loads with zero
      # reassembly failures) and the console on the mini-UART, which is
      # what BOARD_KERNEL_CMDLINE already says. Verify on the device with:
      #     for a in serial0 serial1; do cat /proc/device-tree/aliases/$a; done
      #
      # See pi/docs/04_IMAGE_REBUILD_GUIDE.md and
      # docs/os-corrections-2026-08-16.md §1.
      if grep -q '^dtoverlay=miniuart-bt' "$CFG"; then
        echo '[customize] - boot/config.txt: disabling dtoverlay=miniuart-bt (breaks BT *and* console)'
        sed -i 's/^dtoverlay=miniuart-bt/#dtoverlay=miniuart-bt/' "$CFG"
      fi

      # Paired revert — the console must point at the mini-UART (ttyS0),
      # which is where it lands once the overlay is gone.
      BOARDCFG="$DEV_DIR/BoardConfig.mk"
      if [ -f "$BOARDCFG" ] && grep -q 'console=ttyAMA0,115200' "$BOARDCFG"; then
        echo '[customize] + BoardConfig.mk: console=ttyAMA0 -> console=ttyS0 (miniuart-bt removed)'
        sed -i 's/console=ttyAMA0,115200/console=ttyS0,115200/g' "$BOARDCFG"
      fi

      ;;
    rpi5)
      # Pi 5: the dedicated 3-pin debug UART (ttyAMA10) is the console by
      # default. Leave it alone. If the user wants to force console onto
      # GPIO 14/15 instead, they'd add `dtparam=uart0_console` here.
      echo '[customize] Pi 5 console = ttyAMA10 on 3-pin JST SH debug header (default). No change.'
      ;;
  esac
fi

# ---------------------------------------------------------------------
# 2. Ethernet DHCP + adbd-over-TCP as "root shell on RJ45"
# ---------------------------------------------------------------------
# This is the MVP for "root must be available via SSH on ethernet".
# userdebug builds already allow `adb root`; we expose adbd on TCP 5555
# and ensure eth0 comes up with DHCP at boot. Pair with:
#     adb connect <pi-ip>:5555
#     adb root
#     adb shell           # root shell over the network
#
# IMPLEMENTATION NOTE (fixed 2026-04-13):
# Previously we wrote a `system.prop` file under device/brcm/rpi4/.
# The props did not land in the built image because:
#   (a) raspberry-vanilla's device tree uses TARGET_VENDOR_PROP (pointing
#       at vendor.prop) but does NOT set TARGET_SYSTEM_PROP, and
#   (b) the legacy `$(wildcard $(TARGET_DEVICE_DIR)/system.prop)` path
#       no longer reliably feeds into the Soong-built system-build.prop
#       module in Android 16.
# The canonical Android 16 mechanism per source.android.com/docs/core/
# architecture/configuration/add-system-properties is PRODUCT_SYSTEM_
# PROPERTIES in the product/device makefile, which flows into
# system/build.prop (where init reads persist.* during early boot).
# ---------------------------------------------------------------------
DEVICE_MK="$DEV_DIR/device.mk"
AAOS_MARKER='# --- AAOS custom ---'
AAOS_PROPS_MARKER='# --- AAOS custom props ---'
if [ -f "$DEVICE_MK" ] && ! grep -qF "$AAOS_PROPS_MARKER" "$DEVICE_MK"; then
  echo '[customize] + device.mk: PRODUCT_SYSTEM_PROPERTIES (adbd-tcp, ethernet)'
  cat >> "$DEVICE_MK" <<EOF

$AAOS_PROPS_MARKER
# adbd-over-TCP on port 5555 (userdebug) + ethernet on by default.
# These land in system/build.prop; init reads them on boot.
# See scripts/vm/apply-customizations.sh.
PRODUCT_SYSTEM_PROPERTIES += \\
    persist.adb.tcp.port=5555 \\
    service.adb.tcp.port=5555 \\
    persist.sys.ethernet.enable=1 \\
    ro.tether.denied=false
EOF
fi

# Clean up the legacy (broken) system.prop if it was written by an
# older revision of this script — harmless but noisy.
LEGACY_SYS_PROP="$DEV_DIR/system.prop"
if [ -f "$LEGACY_SYS_PROP" ] && grep -q '^persist.adb.tcp.port=' "$LEGACY_SYS_PROP"; then
  echo "[customize] removing legacy (unconsumed) $LEGACY_SYS_PROP"
  rm -f "$LEGACY_SYS_PROP"
fi

# Overlay-provided .rc files (optional)
if [ -d /mnt/overlays/init ]; then
  mkdir -p "$DEV_DIR/root"
  shopt -s nullglob
  for rc in /mnt/overlays/init/*.rc; do
    echo "[customize] init overlay: $(basename "$rc")"
    cp -f "$rc" "$DEV_DIR/root/"
  done
  shopt -u nullglob
fi

# Overlay-provided SSH authorized_keys (future use with dropbear)
if [ -f /mnt/overlays/ssh/authorized_keys ]; then
  mkdir -p "$DEV_DIR/root/root_ssh"
  cp -f /mnt/overlays/ssh/authorized_keys "$DEV_DIR/root/root_ssh/"
  echo '[customize] ssh authorized_keys staged for future dropbear use'
fi

# ---------------------------------------------------------------------
# 5. CPU governor = performance (via kernel cmdline)
# ---------------------------------------------------------------------
# Pi 4 (Cortex-A72) and Pi 5 (Cortex-A76) default to `ondemand` /
# `schedutil` in mainline, which hurts responsiveness under AAOS.
# `cpufreq.default_governor=performance` forces all cpufreq policies
# to lock to the highest frequency at kernel init — takes effect from
# the very first userspace instruction. Android's PowerHAL may retune
# later, but for a workstation/test build this is the right default.
#
# Appended to BOARD_KERNEL_CMDLINE in BoardConfig.mk (with += so the
# existing cmdline is preserved).
# ---------------------------------------------------------------------
BOARDCFG="$DEV_DIR/BoardConfig.mk"
AAOS_MARKER='# --- AAOS custom ---'
if [ -f "$BOARDCFG" ] && ! grep -qF "cpufreq.default_governor=performance" "$BOARDCFG"; then
  echo '[customize] + BoardConfig.mk: cpufreq.default_governor=performance'
  cat >> "$BOARDCFG" <<EOF

$AAOS_MARKER
# CPU governor forced to performance at boot — see scripts/vm/apply-customizations.sh
BOARD_KERNEL_CMDLINE += cpufreq.default_governor=performance
EOF
fi

# ---------------------------------------------------------------------
# 6. DocumentsUI ("Files" app) in PRODUCT_PACKAGES
# ---------------------------------------------------------------------
# Raspberry-vanilla's device.mk does NOT include any user-facing file
# browser — the PRODUCT_PACKAGES list is all HAL APEXes. We add
# DocumentsUI so the Files intent works and apps can open files via
# the document picker. Note: the AAOS Car Launcher may not show
# DocumentsUI as a tile by default (it filters by CATEGORY_LAUNCHER
# with car-specific metadata); if so, launch it from a terminal with:
#
#   adb shell am start -a android.intent.action.VIEW \
#       -d content://com.android.externalstorage.documents/root/primary
#
# or:
#
#   adb shell am start -n com.android.documentsui/.files.FilesActivity
# ---------------------------------------------------------------------
DEVICE_MK="$DEV_DIR/device.mk"
if [ -f "$DEVICE_MK" ] && ! grep -qF 'PRODUCT_PACKAGES += DocumentsUI' "$DEVICE_MK"; then
  echo '[customize] + device.mk: DocumentsUI (Files app)'
  cat >> "$DEVICE_MK" <<EOF

$AAOS_MARKER
# Files app — see scripts/vm/apply-customizations.sh
PRODUCT_PACKAGES += DocumentsUI
EOF
fi

echo '[customize] done.'

# ---------------------------------------------------------------------
# Post-build verification helper
# ---------------------------------------------------------------------
# After `m` completes, run this script with `verify` as the second arg
# to confirm the props actually landed in the built system image.
# Example:
#   apply-customizations.sh pi4 verify
# ---------------------------------------------------------------------
if [ "${2:-}" = "verify" ]; then
  OUT_BP="$AOSP_DIR/out/target/product/$BOARD/system/build.prop"
  echo "[verify] checking $OUT_BP"
  if [ ! -f "$OUT_BP" ]; then
    echo "[verify] FAIL: $OUT_BP does not exist — build not complete?"
    exit 2
  fi
  missing=0
  for key in persist.adb.tcp.port service.adb.tcp.port persist.sys.ethernet.enable; do
    if grep -q "^${key}=" "$OUT_BP"; then
      echo "[verify] OK  ${key}=$(grep "^${key}=" "$OUT_BP" | head -1 | cut -d= -f2-)"
    else
      echo "[verify] MISS ${key} not present in system/build.prop"
      missing=$((missing+1))
    fi
  done
  [ "$missing" -eq 0 ] || exit 3
  echo "[verify] all props present in system/build.prop"
fi
