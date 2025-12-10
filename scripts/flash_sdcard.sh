#!/bin/bash
#
# Flash AAOS image to SD card for Raspberry Pi 5
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
echo "AAOS Flash Tool for Raspberry Pi 5"
echo "=============================================="

# Check for device argument
if [ -z "$1" ]; then
    echo ""
    echo "Usage: $0 /dev/sdX"
    echo ""
    echo "Available devices:"
    lsblk -d -o NAME,SIZE,MODEL | grep -E "^sd|^mmcblk"
    echo ""
    echo -e "${YELLOW}WARNING: Select the correct device! Wrong selection will destroy data.${NC}"
    exit 1
fi

DEVICE="$1"

# Safety checks
if [ ! -b "$DEVICE" ]; then
    echo -e "${RED}Error: $DEVICE is not a valid block device.${NC}"
    exit 1
fi

# Prevent flashing to system drive
if mount | grep -q "^$DEVICE"; then
    MOUNT_POINT=$(mount | grep "^$DEVICE" | awk '{print $3}')
    if [ "$MOUNT_POINT" = "/" ] || [ "$MOUNT_POINT" = "/home" ] || [ "$MOUNT_POINT" = "/boot" ]; then
        echo -e "${RED}Error: Cannot flash to mounted system partition!${NC}"
        exit 1
    fi
fi

# Check for image - look for RaspberryVanillaAOSP16 images first (from rpi5-mkimg.sh)
IMAGE_FILE=""
VANILLA_IMG=$(ls -t "$PRODUCT_DIR"/RaspberryVanillaAOSP16-*.img 2>/dev/null | head -1)
if [ -n "$VANILLA_IMG" ] && [ -f "$VANILLA_IMG" ]; then
    IMAGE_FILE="$VANILLA_IMG"
elif [ -f "$PRODUCT_DIR/rpi5.img" ]; then
    IMAGE_FILE="$PRODUCT_DIR/rpi5.img"
elif [ -f "$PRODUCT_DIR/aosp_rpi5_car.img" ]; then
    IMAGE_FILE="$PRODUCT_DIR/aosp_rpi5_car.img"
elif [ -f "$PRODUCT_DIR/rpi5.img.xz" ]; then
    IMAGE_FILE="$PRODUCT_DIR/rpi5.img.xz"
else
    echo -e "${RED}Error: No flashable image found in $PRODUCT_DIR${NC}"
    echo "Looking for: RaspberryVanillaAOSP16-*.img, rpi5.img, aosp_rpi5_car.img, or rpi5.img.xz"
    exit 1
fi

# Check for TWRP recovery image
if [ -f "$PRODUCT_DIR/recovery.img" ]; then
    echo -e "${GREEN}TWRP recovery image found.${NC}"
else
    echo -e "${YELLOW}Warning: recovery.img not found. TWRP may not be included.${NC}"
fi

echo ""
echo "Image file: $IMAGE_FILE"
echo "Target device: $DEVICE"
echo ""
echo -e "${RED}WARNING: ALL DATA ON $DEVICE WILL BE DESTROYED!${NC}"
echo ""
read -p "Type 'YES' to continue: " confirm

if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 0
fi

# Unmount all partitions
echo -e "${YELLOW}Unmounting partitions...${NC}"
# Handle both /dev/sda1 style and /dev/mmcblk0p1 style partition names
for part in ${DEVICE}* ${DEVICE}p*; do
    if [ -b "$part" ] && [ "$part" != "$DEVICE" ]; then
        sudo umount "$part" 2>/dev/null || true
    fi
done

# Flash image
echo -e "${YELLOW}Flashing image to $DEVICE...${NC}"
echo "This will take several minutes..."

if [[ "$IMAGE_FILE" == *.xz ]]; then
    # Compressed image
    xz -dc "$IMAGE_FILE" | sudo dd of="$DEVICE" bs=4M status=progress conv=fsync
else
    # Uncompressed image
    sudo dd if="$IMAGE_FILE" of="$DEVICE" bs=4M status=progress conv=fsync
fi

# Sync and flush buffers
echo -e "${YELLOW}Syncing...${NC}"
sync

# Configure UART in boot partition config.txt
echo -e "${YELLOW}Configuring UART in boot partition...${NC}"

# Handle partition naming: mmcblk0 -> mmcblk0p1, sda -> sda1
# Linux kernel adds 'p' separator when device name ends with digit
if [[ "$DEVICE" =~ [0-9]$ ]]; then
    BOOT_PART="${DEVICE}p1"
else
    BOOT_PART="${DEVICE}1"
fi

if [ -b "$BOOT_PART" ]; then
    BOOT_MOUNT=$(mktemp -d)
    sudo mount "$BOOT_PART" "$BOOT_MOUNT" 2>/dev/null || true

    if [ -f "$BOOT_MOUNT/config.txt" ]; then
        # Add UART configuration for Pi 5 GPIO header (ttyAMA0)
        # Physical pins 8 (TX) and 10 (RX) = BCM GPIO 14/15
        if ! grep -q "dtparam=uart0" "$BOOT_MOUNT/config.txt"; then
            echo "" | sudo tee -a "$BOOT_MOUNT/config.txt" > /dev/null
            echo "# UART console on physical pins 8/10 (GPIO 14/15)" | sudo tee -a "$BOOT_MOUNT/config.txt" > /dev/null
            echo "dtparam=uart0=on" | sudo tee -a "$BOOT_MOUNT/config.txt" > /dev/null
            echo "enable_uart=1" | sudo tee -a "$BOOT_MOUNT/config.txt" > /dev/null
            echo -e "${GREEN}UART enabled in config.txt (ttyAMA0 on GPIO 14/15)${NC}"
        fi
        sync
    fi

    sudo umount "$BOOT_MOUNT" 2>/dev/null || true
    rmdir "$BOOT_MOUNT" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}=============================================="
echo "Flash complete!"
echo "==============================================${NC}"
echo ""
echo "You can now:"
echo "  1. Remove the SD card"
echo "  2. Insert it into your Raspberry Pi 5"
echo "  3. Power on the Pi"
echo ""
echo "First boot may take a few minutes."
echo ""
echo "Access methods after boot:"
echo "  - ADB: adb connect <pi-ip-address>:5555"
echo "  - ADB root: adb root (already enabled)"
echo "  - SSH: ssh root@<pi-ip-address> (once SSH is configured)"
echo "  - UART: Physical pins 8 (TX) / 10 (RX) at 115200 baud"
echo "         Device: /dev/ttyAMA0 (NOT ttyAMA10 which is the debug header)"
echo ""
echo "TWRP Recovery:"
echo "  - Boot to recovery: adb reboot recovery"
echo "  - Or hold volume down during boot (if supported)"
echo ""
