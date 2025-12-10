#!/bin/bash
#
# AOSP Android 16 Automotive OS Build Script
# Builds AAOS for Raspberry Pi 5 with root access, SSH, and TWRP recovery
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build directory
if [ -f "$SCRIPT_DIR/.build_dir" ]; then
    BUILD_DIR=$(cat "$SCRIPT_DIR/.build_dir")
else
    BUILD_DIR="$HOME/aosp-aaos-rpi5"
fi

# ===========================================
# LOAD SETTINGS FROM CONFIG FILE
# ===========================================
load_settings() {
    SETTINGS_FILE="$SCRIPT_DIR/settings.conf"

    if [ -f "$SETTINGS_FILE" ]; then
        echo -e "${CYAN}Loading settings from settings.conf...${NC}"
        # Source the settings file (only variables, skip comments)
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            # Remove quotes from value
            value="${value%\"}"
            value="${value#\"}"
            # Export the variable
            export "$key=$value"
        done < <(grep -v '^#' "$SETTINGS_FILE" | grep -v '^$' | grep '=')
        echo -e "${GREEN}Settings loaded.${NC}"
    else
        echo -e "${YELLOW}No settings.conf found. Using defaults.${NC}"
        # Set defaults
        export BUILD_VARIANT="car"
        export BUILD_TYPE="userdebug"
        export DISPLAY_DENSITY="240"
        export DISPLAY_RESOLUTION="1920x1080"
        export SCREEN_BRIGHTNESS_DEFAULT="128"
        export SCREEN_BRIGHTNESS_MIN="20"
        export NIGHT_MODE="yes"
        export AUDIO_OUTPUT_DEVICE="hdmi"
        export HDMI_AUDIO_PORT="hdmi0"
        export MEDIA_VOLUME_DEFAULT="20"
        export MEDIA_VOLUME_STEPS="25"
        export WIFI_COUNTRY_CODE="00"
        export WIFI_HOTSPOT_SSID="Raspberry Pi 5"
        export WIFI_5GHZ_ENABLED="yes"
        export WIFI_BACKGROUND_SCAN="yes"
        export BLUETOOTH_ENABLED="no"
        export HDMI_CEC_ENABLED="yes"
        export HDMI_CEC_DEVICE="cec0"
        export HDMI_CEC_STANDBY_ON_SLEEP="no"
        export USB_GADGET_MODE="mtp,adb"
        export USB_MANUFACTURER="Raspberry"
        export USB_PRODUCT="Pi 5"
        export UART_CONSOLE_ENABLED="yes"
        export UART_DEVICE="ttyAMA0"
        export UART_BAUD_RATE="115200"
        export UART_EARLY_CONSOLE="yes"
        export ROOT_ACCESS_ENABLED="yes"
        export ADB_ROOT_ENABLED="yes"
        export SSH_ENABLED="yes"
        export SELINUX_MODE="permissive"
        export DISABLE_PACKAGE_VERIFICATION="yes"
        export SKIP_SETUP_WIZARD="yes"
        export DISABLE_LOCKSCREEN="yes"
        export STAY_ON_WHILE_PLUGGED="yes"
        export LOCATION_ENABLED="no"
        export PARTITION_BOOT_MB="256"
        export PARTITION_SYSTEM_MB="4096"
        export PARTITION_VENDOR_MB="512"
        export PARTITION_USERDATA_MB="1024"
        export DEVICE_SERIAL="rpi5"
        export DEVICE_NAME="Raspberry Pi 5"
        export CAMERA_ENABLED="yes"
        export CAMERA_SENSOR=""
        export CAR_EVS_ENABLED="yes"
        export CAR_EVS_CAMERA="/dev/video0"
        export CAR_CAN_ENABLED="no"
        export BUILD_JOBS="0"
        export CCACHE_SIZE_GB="50"
        export HDR_ENABLED="no"
        export DESKTOP_MODE_ENABLED="yes"
    fi
}

# Show current settings summary
show_settings() {
    echo ""
    echo -e "${CYAN}Current Build Settings:${NC}"
    echo "  Build Variant:     $BUILD_VARIANT"
    echo "  Build Type:        $BUILD_TYPE"
    echo "  Display:           ${DISPLAY_RESOLUTION:-auto} @ ${DISPLAY_DENSITY}dpi"
    echo "  Audio Output:      $AUDIO_OUTPUT_DEVICE ($HDMI_AUDIO_PORT)"
    echo "  WiFi Country:      $WIFI_COUNTRY_CODE"
    echo "  UART Console:      $UART_DEVICE @ ${UART_BAUD_RATE}bps"
    echo "  Root Access:       $ROOT_ACCESS_ENABLED"
    echo "  SELinux:           $SELINUX_MODE"
    echo "  Partitions:        boot=${PARTITION_BOOT_MB}MB sys=${PARTITION_SYSTEM_MB}MB"
    echo ""
}

# Load settings at script start
load_settings

echo "=============================================="
echo "AOSP Android 16 Automotive Build"
echo "=============================================="
echo "Build directory: $BUILD_DIR"
echo ""

if [ ! -d "$BUILD_DIR/.repo" ]; then
    echo -e "${RED}Error: AOSP source not found. Run sync_aosp.sh first.${NC}"
    exit 1
fi

cd "$BUILD_DIR"

# Apply custom overlays
apply_overlays() {
    echo -e "${YELLOW}Applying custom root/SSH overlays...${NC}"

    # Copy init.root.rc to device tree
    if [ -d "device/brcm/rpi5" ]; then
        mkdir -p device/brcm/rpi5/rootdir/etc/init
        cp "$SCRIPT_DIR/overlay/device/brcm/rpi5/rootdir/etc/init/init.root.rc" \
           device/brcm/rpi5/rootdir/etc/init/ 2>/dev/null || true

        # Append to device makefile if not already done
        DEVICE_MK="device/brcm/rpi5/device.mk"
        if [ -f "$DEVICE_MK" ] && ! grep -q "init.root.rc" "$DEVICE_MK"; then
            echo "" >> "$DEVICE_MK"
            echo "# Root and SSH support" >> "$DEVICE_MK"
            echo "PRODUCT_COPY_FILES += \\" >> "$DEVICE_MK"
            echo "    device/brcm/rpi5/rootdir/etc/init/init.root.rc:\$(TARGET_COPY_OUT_SYSTEM)/etc/init/init.root.rc" >> "$DEVICE_MK"
        fi

        echo -e "${GREEN}Overlays applied.${NC}"
    else
        echo -e "${YELLOW}Device tree not yet synced. Overlays will be applied after sync.${NC}"
    fi
}

# Create/update build properties for root access
configure_root_access() {
    echo -e "${YELLOW}Configuring root access properties...${NC}"

    # Create a property override file
    PROP_FILE="device/brcm/rpi5/root_props.mk"

    if [ -d "device/brcm/rpi5" ]; then
        # Generate properties based on settings.conf
        cat > "$PROP_FILE" << EOF
# Root access and development properties for AAOS
# Generated from settings.conf - DO NOT EDIT DIRECTLY
# Enables ADB root, SSH, and full root access

EOF

        # Root access properties (conditional)
        if [ "$ROOT_ACCESS_ENABLED" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# Core root access properties
PRODUCT_PROPERTY_OVERRIDES += \\
    ro.adb.secure=0 \\
    ro.secure=0 \\
    ro.debuggable=1 \\
    persist.sys.root_access=3

EOF
        fi

        # ADB root (conditional)
        if [ "$ADB_ROOT_ENABLED" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# ADB root access
PRODUCT_PROPERTY_OVERRIDES += \\
    service.adb.root=1 \\
    persist.service.adb.enable=1

EOF
        fi

        # USB configuration from settings
        cat >> "$PROP_FILE" << EOF
# USB configuration
PRODUCT_PROPERTY_OVERRIDES += \\
    persist.sys.usb.config=$USB_GADGET_MODE \\
    persist.sys.usb.ffs.ready=1

EOF

        # SELinux configuration from settings
        cat >> "$PROP_FILE" << EOF
# SELinux mode ($SELINUX_MODE)
PRODUCT_PROPERTY_OVERRIDES += \\
    ro.boot.selinux=$SELINUX_MODE

EOF

        # SSH configuration (conditional)
        if [ "$SSH_ENABLED" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# SSH configuration
PRODUCT_PROPERTY_OVERRIDES += \\
    persist.sys.ssh.enable=1

EOF
        fi

        # Bootloader unlock
        cat >> "$PROP_FILE" << EOF
# Unlock bootloader status
PRODUCT_PROPERTY_OVERRIDES += \\
    ro.oem_unlock_supported=1 \\
    ro.boot.flash.locked=0

EOF

        # Package verification (conditional)
        if [ "$DISABLE_PACKAGE_VERIFICATION" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# Disable package verification for sideloading
PRODUCT_PROPERTY_OVERRIDES += \\
    persist.sys.pkg.disable_verification=1

EOF
        fi

        # UART serial console configuration from settings
        if [ "$UART_CONSOLE_ENABLED" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# UART serial console configuration ($UART_DEVICE on GPIO pins 8/10)
PRODUCT_PROPERTY_OVERRIDES += \\
    ro.boot.console=$UART_DEVICE \\
    ro.serialno=$DEVICE_SERIAL

EOF
        fi

        # Display settings
        cat >> "$PROP_FILE" << EOF
# Display settings
PRODUCT_PROPERTY_OVERRIDES += \\
    ro.sf.lcd_density=$DISPLAY_DENSITY

EOF

        # Audio settings
        cat >> "$PROP_FILE" << EOF
# Audio settings
PRODUCT_PROPERTY_OVERRIDES += \\
    persist.vendor.audio.device=$HDMI_AUDIO_PORT \\
    ro.config.media_vol_default=$MEDIA_VOLUME_DEFAULT \\
    ro.config.media_vol_steps=$MEDIA_VOLUME_STEPS

EOF

        # WiFi settings
        cat >> "$PROP_FILE" << EOF
# WiFi settings
PRODUCT_PROPERTY_OVERRIDES += \\
    ro.boot.wificountrycode=$WIFI_COUNTRY_CODE

EOF

        # HDMI CEC settings
        if [ "$HDMI_CEC_ENABLED" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# HDMI CEC settings
PRODUCT_PROPERTY_OVERRIDES += \\
    persist.vendor.hdmi.cec_device=$HDMI_CEC_DEVICE

EOF
        fi

        # Bluetooth settings
        if [ "$BLUETOOTH_ENABLED" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# Bluetooth enabled by default
PRODUCT_PROPERTY_OVERRIDES += \\
    persist.bluetooth.btsnoopenable=false \\
    bluetooth.enable_timeout_ms=11000

EOF
        fi

        # Desktop mode
        if [ "$DESKTOP_MODE_ENABLED" = "yes" ]; then
            cat >> "$PROP_FILE" << EOF
# Desktop mode support
PRODUCT_PROPERTY_OVERRIDES += \\
    persist.wm.extensions.enabled=true

EOF
        fi

        # Location settings
        if [ "$LOCATION_ENABLED" = "no" ]; then
            cat >> "$PROP_FILE" << EOF
# Location disabled by default
PRODUCT_PROPERTY_OVERRIDES += \\
    ro.com.google.gmsversion=

EOF
        fi

        # Include in main device.mk
        if ! grep -q "root_props.mk" device/brcm/rpi5/device.mk 2>/dev/null; then
            echo "" >> device/brcm/rpi5/device.mk
            echo "# Include root access properties" >> device/brcm/rpi5/device.mk
            echo "-include device/brcm/rpi5/root_props.mk" >> device/brcm/rpi5/device.mk
        fi

        echo -e "${GREEN}Root properties configured from settings.conf.${NC}"
    fi
}

# Configure partition sizes (override upstream defaults)
configure_partitions() {
    echo -e "${YELLOW}Configuring partition sizes from settings.conf...${NC}"

    if [ -d "device/brcm/rpi5" ]; then
        BOARD_CONFIG="device/brcm/rpi5/BoardConfig.mk"

        # Calculate partition sizes in bytes from MB settings
        BOOT_SIZE=$((PARTITION_BOOT_MB * 1024 * 1024))
        SYSTEM_SIZE=$((PARTITION_SYSTEM_MB * 1024 * 1024))
        VENDOR_SIZE=$((PARTITION_VENDOR_MB * 1024 * 1024))
        USERDATA_SIZE=$((PARTITION_USERDATA_MB * 1024 * 1024))

        # Remove existing custom partition sizes if present
        if [ -f "$BOARD_CONFIG" ]; then
            sed -i '/# Custom partition sizes/,/BOARD_USERDATAIMAGE_PARTITION_SIZE/d' "$BOARD_CONFIG" 2>/dev/null || true
        fi

        echo "" >> "$BOARD_CONFIG"
        echo "# Custom partition sizes (from settings.conf)" >> "$BOARD_CONFIG"
        echo "BOARD_BOOTIMAGE_PARTITION_SIZE := $BOOT_SIZE" >> "$BOARD_CONFIG"        # ${PARTITION_BOOT_MB} MB
        echo "BOARD_SYSTEMIMAGE_PARTITION_SIZE := $SYSTEM_SIZE" >> "$BOARD_CONFIG"    # ${PARTITION_SYSTEM_MB} MB
        echo "BOARD_VENDORIMAGE_PARTITION_SIZE := $VENDOR_SIZE" >> "$BOARD_CONFIG"    # ${PARTITION_VENDOR_MB} MB
        echo "BOARD_USERDATAIMAGE_PARTITION_SIZE := $USERDATA_SIZE" >> "$BOARD_CONFIG" # ${PARTITION_USERDATA_MB} MB

        echo -e "${GREEN}Partition sizes: boot=${PARTITION_BOOT_MB}MB sys=${PARTITION_SYSTEM_MB}MB vendor=${PARTITION_VENDOR_MB}MB data=${PARTITION_USERDATA_MB}MB${NC}"
    fi
}

# Configure SELinux and UART from settings.conf
configure_selinux() {
    echo -e "${YELLOW}Configuring SELinux and UART from settings.conf...${NC}"

    if [ -d "device/brcm/rpi5" ]; then
        BOARD_CONFIG="device/brcm/rpi5/BoardConfig.mk"

        if [ -f "$BOARD_CONFIG" ]; then
            # Configure UART console based on settings
            if [ "$UART_CONSOLE_ENABLED" = "yes" ]; then
                # Replace any existing ttyAMA references with the configured device
                if grep -q "ttyAMA10" "$BOARD_CONFIG"; then
                    sed -i "s/console=ttyAMA10,[0-9]*/console=$UART_DEVICE,$UART_BAUD_RATE/g" "$BOARD_CONFIG"
                    echo -e "${GREEN}Updated UART to $UART_DEVICE @ ${UART_BAUD_RATE}bps${NC}"
                elif grep -q "console=ttyAMA" "$BOARD_CONFIG"; then
                    sed -i "s/console=ttyAMA[0-9]*,[0-9]*/console=$UART_DEVICE,$UART_BAUD_RATE/g" "$BOARD_CONFIG"
                    echo -e "${GREEN}Updated UART to $UART_DEVICE @ ${UART_BAUD_RATE}bps${NC}"
                else
                    echo "" >> "$BOARD_CONFIG"
                    echo "# UART serial console (from settings.conf)" >> "$BOARD_CONFIG"
                    echo "BOARD_KERNEL_CMDLINE += console=$UART_DEVICE,$UART_BAUD_RATE" >> "$BOARD_CONFIG"
                    echo -e "${GREEN}Added $UART_DEVICE console to kernel cmdline${NC}"
                fi

                # Add earlycon for early boot UART output if enabled
                if [ "$UART_EARLY_CONSOLE" = "yes" ] && ! grep -q "earlycon=pl011" "$BOARD_CONFIG"; then
                    echo "" >> "$BOARD_CONFIG"
                    echo "# Early console for boot debugging (from settings.conf)" >> "$BOARD_CONFIG"
                    echo "BOARD_KERNEL_CMDLINE += earlycon=pl011,0xfe201000" >> "$BOARD_CONFIG"
                fi
            fi

            # Configure SELinux mode from settings
            if ! grep -q "BOARD_KERNEL_CMDLINE.*androidboot.selinux" "$BOARD_CONFIG"; then
                sed -i "s/BOARD_KERNEL_CMDLINE :=/BOARD_KERNEL_CMDLINE := androidboot.selinux=$SELINUX_MODE/" "$BOARD_CONFIG" 2>/dev/null || \
                echo "BOARD_KERNEL_CMDLINE += androidboot.selinux=$SELINUX_MODE" >> "$BOARD_CONFIG"
            else
                # Update existing SELinux setting
                sed -i "s/androidboot.selinux=[a-z]*/androidboot.selinux=$SELINUX_MODE/g" "$BOARD_CONFIG"
            fi

            # Show final kernel cmdline for verification
            echo -e "${CYAN}Final BOARD_KERNEL_CMDLINE entries:${NC}"
            grep "BOARD_KERNEL_CMDLINE" "$BOARD_CONFIG" | head -5
        fi

        echo -e "${GREEN}SELinux ($SELINUX_MODE) and UART ($UART_DEVICE) configured.${NC}"
    fi
}

# Configure SSH - Note: AOSP's external/openssh doesn't provide buildable modules by default
# SSH will need to be added post-build or via a custom implementation
setup_ssh() {
    echo -e "${YELLOW}Configuring SSH support...${NC}"

    if [ -d "device/brcm/rpi5" ] && [ -f "device/brcm/rpi5/device.mk" ]; then
        # Remove any previously added broken SSH package entries
        if grep -q "# SSH Server packages" device/brcm/rpi5/device.mk; then
            echo -e "${YELLOW}Removing broken SSH package entries from device.mk...${NC}"
            # Remove the SSH block (from "# SSH Server packages" to the next blank line or section)
            sed -i '/# SSH Server packages/,/^$/d' device/brcm/rpi5/device.mk
            # Also remove any dangling scp/sftp/ssh entries
            sed -i '/^[[:space:]]*scp[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*sftp[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*ssh[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*sshd[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*ssh-keygen[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*sshd_config[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*start-ssh[[:space:]]*$/d' device/brcm/rpi5/device.mk
        fi

        # Note: AOSP's external/openssh is not built by default and requires additional setup
        # SSH access can be achieved post-build by:
        # 1. Using ADB port forwarding: adb forward tcp:2222 tcp:22
        # 2. Installing Termux or similar with SSH server
        # 3. Building a custom SSH solution
        echo -e "${YELLOW}Note: Native SSH requires custom build configuration.${NC}"
        echo -e "${YELLOW}For now, use 'adb shell' for root access.${NC}"
        echo -e "${GREEN}SSH configuration check complete.${NC}"
    else
        echo -e "${YELLOW}Device tree not ready.${NC}"
    fi
}

# Note: TWRP recovery is not compatible with Android 16's build system
# The Android.mk build files are blocked in bootable/ directory
# TWRP will need to be updated to use Android.bp (Blueprint) before it can be integrated

# Main build function
build_aaos() {
    # Determine build target based on settings
    case "$BUILD_VARIANT" in
        car)
            LUNCH_TARGET="aosp_rpi5_car"
            VARIANT_DESC="Automotive"
            ;;
        tablet)
            LUNCH_TARGET="aosp_rpi5"
            VARIANT_DESC="Tablet"
            ;;
        tv)
            LUNCH_TARGET="aosp_rpi5_tv"
            VARIANT_DESC="Android TV"
            ;;
        *)
            LUNCH_TARGET="aosp_rpi5_car"
            VARIANT_DESC="Automotive (default)"
            ;;
    esac

    echo ""
    echo -e "${CYAN}=============================================="
    echo "Starting AAOS Build for Raspberry Pi 5"
    echo "Target: ${LUNCH_TARGET}-${BUILD_TYPE} ($VARIANT_DESC)"
    echo "==============================================${NC}"
    echo ""
    show_settings

    # Source build environment
    source build/envsetup.sh

    # Select target based on settings
    # Android 16 uses new format: lunch PRODUCT RELEASE VARIANT
    echo -e "${YELLOW}Running: lunch $LUNCH_TARGET trunk_staging $BUILD_TYPE${NC}"
    lunch $LUNCH_TARGET trunk_staging $BUILD_TYPE

    # Calculate optimal job count
    if [ "$BUILD_JOBS" = "0" ] || [ -z "$BUILD_JOBS" ]; then
        JOBS=$(nproc)
        MEM_GB=$(free -g | awk '/^Mem:/{print $2}')

        # Use 2GB per job rule
        MEM_JOBS=$((MEM_GB / 2))
        if [ "$MEM_JOBS" -lt "$JOBS" ]; then
            JOBS=$MEM_JOBS
        fi
        if [ "$JOBS" -lt 1 ]; then
            JOBS=1
        fi
    else
        JOBS=$BUILD_JOBS
    fi

    echo -e "${YELLOW}Building with $JOBS parallel jobs...${NC}"
    echo "This will take several hours (4-8+ hours depending on hardware)"
    echo ""

    # Build AAOS (uses stock AOSP recovery - TWRP not compatible with Android 16)
    make -j$JOBS

    # Create flashable image
    echo -e "${YELLOW}Creating flashable SD card image...${NC}"

    if [ -f "rpi5-mkimg.sh" ]; then
        ./rpi5-mkimg.sh
    elif [ -f "device/brcm/rpi5/rpi5-mkimg.sh" ]; then
        ./device/brcm/rpi5/rpi5-mkimg.sh
    else
        echo -e "${YELLOW}Image creation script not found. Manual image creation may be required.${NC}"
    fi

    echo ""
    echo -e "${GREEN}=============================================="
    echo "Build Complete!"
    echo "==============================================${NC}"
    echo ""
    echo "Output images are in: $BUILD_DIR/out/target/product/rpi5/"
    echo ""
    echo "To flash to SD card, run:"
    echo "  ./flash_sdcard.sh /dev/sdX"
    echo ""
}

# Show menu
show_menu() {
    echo "Build Options:"
    echo "  1) Apply overlays only (configure source tree)"
    echo "  2) Full build (apply overlays + build)"
    echo "  3) Resume build (just run make)"
    echo "  4) Clean build (make clean + full build)"
    echo "  5) Show current settings"
    echo "  6) Edit settings (opens settings.conf)"
    echo ""
    read -p "Select option [2]: " option
    option=${option:-2}
}

# Main
main() {
    show_menu

    case $option in
        1)
            apply_overlays
            configure_root_access
            configure_partitions
            configure_selinux
            setup_ssh
            echo -e "${GREEN}Overlays applied. Run option 2 or 3 to build.${NC}"
            ;;
        2)
            apply_overlays
            configure_root_access
            configure_partitions
            configure_selinux
            setup_ssh
            build_aaos
            ;;
        3)
            build_aaos
            ;;
        4)
            source build/envsetup.sh
            # Determine lunch target from settings
            case "$BUILD_VARIANT" in
                car) LUNCH_TARGET="aosp_rpi5_car" ;;
                tablet) LUNCH_TARGET="aosp_rpi5" ;;
                tv) LUNCH_TARGET="aosp_rpi5_tv" ;;
                *) LUNCH_TARGET="aosp_rpi5_car" ;;
            esac
            lunch $LUNCH_TARGET trunk_staging $BUILD_TYPE
            make clean
            apply_overlays
            configure_root_access
            configure_partitions
            configure_selinux
            setup_ssh
            build_aaos
            ;;
        5)
            echo ""
            echo -e "${CYAN}=============================================="
            echo "Current Build Settings (from settings.conf)"
            echo "==============================================${NC}"
            show_settings
            echo -e "${CYAN}Full settings file: $SCRIPT_DIR/settings.conf${NC}"
            echo ""
            # Show all settings categories
            echo -e "${YELLOW}All configured values:${NC}"
            echo ""
            echo "BUILD VARIANT:"
            echo "  BUILD_VARIANT=$BUILD_VARIANT"
            echo "  BUILD_TYPE=$BUILD_TYPE"
            echo ""
            echo "DISPLAY:"
            echo "  DISPLAY_DENSITY=$DISPLAY_DENSITY"
            echo "  DISPLAY_RESOLUTION=$DISPLAY_RESOLUTION"
            echo "  SCREEN_BRIGHTNESS_DEFAULT=$SCREEN_BRIGHTNESS_DEFAULT"
            echo "  NIGHT_MODE=$NIGHT_MODE"
            echo ""
            echo "AUDIO:"
            echo "  AUDIO_OUTPUT_DEVICE=$AUDIO_OUTPUT_DEVICE"
            echo "  HDMI_AUDIO_PORT=$HDMI_AUDIO_PORT"
            echo "  MEDIA_VOLUME_DEFAULT=$MEDIA_VOLUME_DEFAULT"
            echo ""
            echo "NETWORK:"
            echo "  WIFI_COUNTRY_CODE=$WIFI_COUNTRY_CODE"
            echo "  WIFI_5GHZ_ENABLED=$WIFI_5GHZ_ENABLED"
            echo "  BLUETOOTH_ENABLED=$BLUETOOTH_ENABLED"
            echo ""
            echo "HDMI CEC:"
            echo "  HDMI_CEC_ENABLED=$HDMI_CEC_ENABLED"
            echo "  HDMI_CEC_DEVICE=$HDMI_CEC_DEVICE"
            echo ""
            echo "UART CONSOLE:"
            echo "  UART_CONSOLE_ENABLED=$UART_CONSOLE_ENABLED"
            echo "  UART_DEVICE=$UART_DEVICE"
            echo "  UART_BAUD_RATE=$UART_BAUD_RATE"
            echo ""
            echo "DEVELOPMENT:"
            echo "  ROOT_ACCESS_ENABLED=$ROOT_ACCESS_ENABLED"
            echo "  ADB_ROOT_ENABLED=$ADB_ROOT_ENABLED"
            echo "  SSH_ENABLED=$SSH_ENABLED"
            echo "  SELINUX_MODE=$SELINUX_MODE"
            echo ""
            echo "PARTITIONS:"
            echo "  PARTITION_BOOT_MB=$PARTITION_BOOT_MB"
            echo "  PARTITION_SYSTEM_MB=$PARTITION_SYSTEM_MB"
            echo "  PARTITION_VENDOR_MB=$PARTITION_VENDOR_MB"
            echo "  PARTITION_USERDATA_MB=$PARTITION_USERDATA_MB"
            echo ""
            echo "DEVICE:"
            echo "  DEVICE_NAME=$DEVICE_NAME"
            echo "  DEVICE_SERIAL=$DEVICE_SERIAL"
            echo ""
            if [ "$BUILD_VARIANT" = "car" ]; then
                echo "CAR-SPECIFIC:"
                echo "  CAR_EVS_ENABLED=$CAR_EVS_ENABLED"
                echo "  CAR_CAN_ENABLED=$CAR_CAN_ENABLED"
                echo ""
            fi
            ;;
        6)
            SETTINGS_FILE="$SCRIPT_DIR/settings.conf"
            if [ -f "$SETTINGS_FILE" ]; then
                # Try to open with user's preferred editor
                if [ -n "$EDITOR" ]; then
                    $EDITOR "$SETTINGS_FILE"
                elif command -v nano &> /dev/null; then
                    nano "$SETTINGS_FILE"
                elif command -v vim &> /dev/null; then
                    vim "$SETTINGS_FILE"
                elif command -v vi &> /dev/null; then
                    vi "$SETTINGS_FILE"
                else
                    echo -e "${YELLOW}No editor found. Please edit manually:${NC}"
                    echo "  $SETTINGS_FILE"
                fi
                # Reload settings after editing
                echo -e "${CYAN}Reloading settings...${NC}"
                load_settings
                show_settings
            else
                echo -e "${RED}Settings file not found: $SETTINGS_FILE${NC}"
                echo "Creating default settings file..."
                # Trigger creation by running the script again
            fi
            ;;
        *)
            echo "Invalid option"
            exit 1
            ;;
    esac
}

main "$@"
