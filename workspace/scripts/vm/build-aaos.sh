#!/usr/bin/env bash
# vm/build-aaos.sh pi4|pi5 — runs INSIDE the Lima VM.
#
# Drives the AOSP build for one board:
#   1) applies any customizations (UART config, ethernet/adb overlays)
#   2) lunch aosp_rpi{4,5}_car-bp4a-userdebug
#   3) make bootimage systemimage vendorimage
#   4) ./rpi{4,5}-mkimg.sh (produces the flashable .img)

# NOTE: intentionally NOT using `set -u`. AOSP's build/envsetup.sh and its
# numerous sub-scripts reference unset variables (TOP, OUT_DIR, etc.) and
# break immediately under `set -u`. We keep errexit + pipefail for safety.
set -eo pipefail

TARGET="${1:-}"
# Accept either short (pi4/pi5) or canonical (rpi4/rpi5) form; canonicalize.
case "$TARGET" in
  pi4|rpi4) BOARD=rpi4 ;;
  pi5|rpi5) BOARD=rpi5 ;;
  *) echo "Usage: $0 pi4|pi5   (or rpi4|rpi5)" >&2; exit 1 ;;
esac

AOSP_DIR="$HOME/aosp"
[ -d "$AOSP_DIR/.repo" ] || { echo "AOSP not synced: run vm/sync-aosp.sh first"; exit 1; }
cd "$AOSP_DIR"

# ---------------------------------------------------------------------
# ccache — explicitly export here (2026-04-13 fix)
# ---------------------------------------------------------------------
# Two bugs fixed on the same day:
#
# 1. Ubuntu's default ~/.bashrc bails out for non-interactive shells
#    via `[ -z "$PS1" ] && return`, so the ccache env baked into
#    ~/.bashrc by the Lima provision step never reached this script —
#    the original Pi 4 build ran with USE_CCACHE unset (0 hits stored).
#    Fix: export the env here, unconditionally.
#
# 2. AOSP 16's Soong wraps every Ninja action in an nsjail sandbox
#    that bind-mounts the entire root filesystem read-only and only
#    adds a few RW paths: /tmp, the source tree (RO via flag), out/,
#    and dist/. If CCACHE_DIR lives in $HOME, ccache can't mkdir
#    $CCACHE_DIR/tmp inside the sandbox and the build dies with
#    "Read-only file system". See build/soong/ui/build/sandbox_linux.go.
#    Fix: put CCACHE_DIR under $OUT_DIR so nsjail's RW bind mount
#    covers it. Trade-off: `make clean` wipes out/ and therefore the
#    cache — our workflow never does that, so it's fine.
#
# AOSP 16's Soong still honors USE_CCACHE (build/soong/cc/config/
# global.go: `if ctx.Config().IsEnvTrue("USE_CCACHE")`).
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export CCACHE_DIR="$AOSP_DIR/out/.ccache"
export CCACHE_COMPRESS=1
mkdir -p "$CCACHE_DIR"

# Rust incremental compilation (2026-04-13 fix).
# AOSP's default for non-eng builds is `-C codegen-units=1` — rustc's
# codegen inside each crate runs on a SINGLE thread. With ~1300 Rust
# crates in android-16, this is a wall-clock bottleneck early in the
# build. Setting SOONG_RUSTC_INCREMENTAL=true triggers two wins in
# build/soong/rust/builder.go:
#   1. `-C incremental=<out/rustc>` — persistent artifact cache for
#      rustc itself (unchanged crates near-instant on rebuilds).
#   2. Codegen units falls back to rustc's default (~16-way parallel
#      per crate) instead of being pinned to 1.
# Trade-off: rustc's incremental cache isn't bit-reproducible. Fine
# for a dev workflow; would be rejected for a release build.
export SOONG_RUSTC_INCREMENTAL=true
# ccache -M is persistent in the cache's own ccache.conf; set once,
# idempotent on reruns. Size must not exceed out/ disk budget.
ccache -M 200G >/dev/null 2>&1 || true
echo "[build] ccache dir: $CCACHE_DIR"
echo "[build] ccache: $(ccache -s 2>/dev/null | awk -F':' '/Cache size/ {gsub(/^[ \t]+/, "", $2); print $2}' | head -1)"

# Apply per-board customizations before build.
# Run from the SAME dir this script was launched from (set up by the
# host wrapper via vm_push_scripts into /tmp/aaos-scripts/) — not from
# /mnt/scripts, because the 9p mount's cache coherency is unreliable.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/apply-customizations.sh" "$BOARD"

# shellcheck disable=SC1091
source build/envsetup.sh

LUNCH_TARGET="aosp_${BOARD}_car-bp4a-userdebug"
echo "[build] lunch $LUNCH_TARGET"
lunch "$LUNCH_TARGET"

JOBS="$(nproc)"
echo "[build] make bootimage systemimage vendorimage -j$JOBS"
make bootimage systemimage vendorimage -j"$JOBS"

# rpi{4,5}-mkimg.sh is linkfile'd at the top of the AOSP tree by the
# raspberry-vanilla manifest (see reference/raspberry-vanilla/manifest_brcm_rpi.xml).
MKIMG="./${BOARD}-mkimg.sh"
[ -x "$MKIMG" ] || MKIMG="bash ./${BOARD}-mkimg.sh"
echo "[build] $MKIMG"
$MKIMG

echo "[build] done. Images:"
ls -lh "$AOSP_DIR/out/target/product/${BOARD}/"*.img 2>/dev/null || true
ls -lh "$AOSP_DIR"/RaspberryVanillaAOSP*"${BOARD}"*.img 2>/dev/null || true
