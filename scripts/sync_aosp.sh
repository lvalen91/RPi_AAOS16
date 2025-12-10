#!/bin/bash
#
# AOSP Android 16 Automotive OS Sync Script
# Syncs AOSP source with Raspberry Pi 5 device trees
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Script directory (must be set first)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build directory
if [ -f "$SCRIPT_DIR/.build_dir" ]; then
    BUILD_DIR=$(cat "$SCRIPT_DIR/.build_dir")
else
    BUILD_DIR="$HOME/aosp-aaos-rpi5"
fi

echo "=============================================="
echo "AOSP Android 16 Source Sync"
echo "=============================================="
echo "Build directory: $BUILD_DIR"
echo ""

# Create and enter build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Initialize repo if not already done
if [ ! -d ".repo" ]; then
    echo -e "${YELLOW}Initializing AOSP repository...${NC}"

    # Initialize with Android 16
    repo init -u https://android.googlesource.com/platform/manifest \
        -b android-16.0.0_r3 \
        --depth=1 \
        --partial-clone \
        --clone-filter=blob:limit=10M

    echo -e "${GREEN}Repository initialized.${NC}"
else
    echo -e "${GREEN}Repository already initialized.${NC}"
fi

# Create local_manifests directory
mkdir -p .repo/local_manifests

# Download Raspberry Pi manifest
echo -e "${YELLOW}Setting up Raspberry Pi 5 device manifests...${NC}"

curl -o .repo/local_manifests/manifest_brcm_rpi.xml -L \
    https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/android-16.0/manifest_brcm_rpi.xml

# Copy our custom manifests (root/SSH, TWRP recovery)
echo -e "${YELLOW}Adding custom manifests for root/SSH and TWRP recovery...${NC}"
cp "$SCRIPT_DIR/local_manifests/"*.xml .repo/local_manifests/ 2>/dev/null || true

# Sync repositories
echo ""
echo -e "${YELLOW}Syncing AOSP source code...${NC}"
echo "This will take a while (50-100GB download)..."
echo ""

# Calculate optimal job count
JOBS=$(nproc)
if [ "$JOBS" -gt 8 ]; then
    JOBS=8
fi

repo sync -c -j$JOBS --force-sync --no-clone-bundle --no-tags --optimized-fetch

echo ""
echo -e "${GREEN}=============================================="
echo "Source sync complete!"
echo "=============================================="
echo ""
echo "Next steps:"
echo "  1. Run: ./build_aaos.sh"
echo ""
echo -e "${NC}"
