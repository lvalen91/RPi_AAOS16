#!/bin/bash
#
# TWRP Recovery for Raspberry Pi 5
#
# NOTE: TWRP is now built automatically as part of the main AAOS build.
# This script is kept for reference and manual recovery image operations.
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.build_dir" ]; then
    BUILD_DIR=$(cat "$SCRIPT_DIR/.build_dir")
else
    BUILD_DIR="$HOME/aosp-aaos-rpi5"
fi

PRODUCT_DIR="$BUILD_DIR/out/target/product/rpi5"

echo "=============================================="
echo "TWRP Recovery for Raspberry Pi 5"
echo "=============================================="
echo ""

show_menu() {
    echo "TWRP is now integrated into the main AAOS build."
    echo ""
    echo "Options:"
    echo "  1) Rebuild recovery image only (requires completed AAOS build)"
    echo "  2) Check recovery image status"
    echo "  3) Show pre-built TWRP download links (alternative)"
    echo ""
    read -p "Select option [2]: " option
    option=${option:-2}
}

rebuild_recovery() {
    echo -e "${YELLOW}Rebuilding TWRP recovery image...${NC}"

    if [ ! -d "$BUILD_DIR/.repo" ]; then
        echo -e "${RED}Error: AOSP source not found. Run sync_aosp.sh first.${NC}"
        exit 1
    fi

    cd "$BUILD_DIR"
    source build/envsetup.sh
    lunch aosp_rpi5_car-eng

    # Calculate optimal job count
    JOBS=$(nproc)
    MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
    MEM_JOBS=$((MEM_GB / 2))
    if [ "$MEM_JOBS" -lt "$JOBS" ]; then
        JOBS=$MEM_JOBS
    fi
    if [ "$JOBS" -lt 1 ]; then
        JOBS=1
    fi

    make -j$JOBS recoveryimage

    echo ""
    echo -e "${GREEN}TWRP recovery image rebuilt.${NC}"
    check_status
}

check_status() {
    echo ""
    echo "Recovery image locations:"
    echo ""

    if [ -f "$PRODUCT_DIR/recovery.img" ]; then
        SIZE=$(du -h "$PRODUCT_DIR/recovery.img" | cut -f1)
        echo -e "${GREEN}  recovery.img: $PRODUCT_DIR/recovery.img ($SIZE)${NC}"
    else
        echo -e "${YELLOW}  recovery.img: Not found${NC}"
    fi

    if [ -f "$PRODUCT_DIR/boot.img" ]; then
        SIZE=$(du -h "$PRODUCT_DIR/boot.img" | cut -f1)
        echo -e "${GREEN}  boot.img: $PRODUCT_DIR/boot.img ($SIZE)${NC}"
    fi

    echo ""
    echo "The recovery image is automatically included when you run:"
    echo "  ./flash_sdcard.sh /dev/sdX"
    echo ""
}

show_prebuilt() {
    echo ""
    echo "Pre-built TWRP is available as an alternative from KonstaKANG:"
    echo ""
    echo "  https://konstakang.com/devices/rpi5/TWRP/"
    echo ""
    echo "However, TWRP is now built automatically with the AAOS build."
    echo "Use pre-built only if you encounter build issues."
    echo ""
}

main() {
    show_menu

    case $option in
        1)
            rebuild_recovery
            ;;
        2)
            check_status
            ;;
        3)
            show_prebuilt
            ;;
        *)
            echo "Invalid option"
            exit 1
            ;;
    esac
}

main "$@"
