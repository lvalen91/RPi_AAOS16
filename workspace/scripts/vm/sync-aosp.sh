#!/usr/bin/env bash
# vm/sync-aosp.sh — runs INSIDE the Lima VM (Ubuntu 22.04).
#
# Initialises the AOSP repo tree at ~/aosp, pulls the raspberry-vanilla
# Pi 4 + Pi 5 local manifest, drops in any custom manifests from
# /mnt/overlays/local_manifests, and runs repo sync.

set -euo pipefail

AOSP_DIR="$HOME/aosp"
AOSP_BRANCH="android-16.0.0_r4"   # Android 16 QPR2 (April 2026 current)
MANIFEST_REMOTE="https://android.googlesource.com/platform/manifest"
RV_BASE="https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/android-16.0"

mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR"

if [ ! -d .repo ]; then
  echo "[sync] repo init $AOSP_BRANCH (partial clone, blob:limit=10M)"
  repo init \
    -u "$MANIFEST_REMOTE" \
    -b "$AOSP_BRANCH" \
    --partial-clone \
    --clone-filter=blob:limit=10M
else
  echo "[sync] repo tree already initialised; reusing."
fi

echo "[sync] fetching raspberry-vanilla local manifest"
mkdir -p .repo/local_manifests
curl -fsSL "$RV_BASE/manifest_brcm_rpi.xml" \
  -o .repo/local_manifests/manifest_brcm_rpi.xml
curl -fsSL "$RV_BASE/remove_projects.xml" \
  -o .repo/local_manifests/remove_projects.xml

# Overlay any custom manifests from the host (root/SSH, TWRP, …).
if [ -d /mnt/overlays/local_manifests ]; then
  shopt -s nullglob
  for xml in /mnt/overlays/local_manifests/*.xml; do
    echo "[sync] overlay manifest: $(basename "$xml")"
    cp -f "$xml" .repo/local_manifests/
  done
  shopt -u nullglob
fi

# This host is a 24-core / 240 GiB Mac Pro — not a laptop. Push parallelism.
# Network jobs are not CPU-bound; -j32 is the sweet spot before
# android.googlesource.com starts rate-limiting (429) per client IP.
# Override with AOSP_SYNC_JOBS=N to experiment.
JOBS="${AOSP_SYNC_JOBS:-32}"
echo "[sync] repo sync -j$JOBS  (override with AOSP_SYNC_JOBS=N)"
repo sync -c -j"$JOBS" \
  --force-sync \
  --no-clone-bundle \
  --no-tags \
  --optimized-fetch

echo "[sync] done: $AOSP_DIR"
du -sh "$AOSP_DIR" 2>/dev/null || true
