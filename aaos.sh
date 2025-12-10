#!/bin/bash
#
# AAOS All-In-One Build Tool
# Android 16 Automotive OS for Raspberry Pi 5
#
# Combines: setup_build_env.sh, sync_aosp.sh, build_aaos.sh, build_twrp.sh, flash_sdcard.sh
#
# Features:
#   - Root access and ADB root
#   - SSH server support
#   - TWRP recovery
#   - UART serial console
#   - Configurable via settings.conf
#

set -e

# ===========================================
# GLOBAL VARIABLES
# ===========================================
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Build directory
if [ -f "$SCRIPT_DIR/.build_dir" ]; then
    BUILD_DIR=$(cat "$SCRIPT_DIR/.build_dir")
else
    BUILD_DIR="$HOME/aosp-aaos-rpi5"
fi

PRODUCT_DIR="$BUILD_DIR/out/target/product/rpi5"

# ===========================================
# UTILITY FUNCTIONS
# ===========================================
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         AAOS All-In-One Build Tool v${VERSION}                   ║"
    echo "║     Android 16 Automotive OS for Raspberry Pi 5              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        echo -e "${RED}Please do not run this script as root. Run as regular user.${NC}"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        echo -e "${RED}Cannot detect OS. This script supports Ubuntu/Debian/Fedora.${NC}"
        exit 1
    fi
}

press_enter_to_continue() {
    echo ""
    read -p "Press Enter to continue..."
}

# ===========================================
# SETTINGS MANAGEMENT
# ===========================================
load_settings() {
    SETTINGS_FILE="$SCRIPT_DIR/settings.conf"

    if [ -f "$SETTINGS_FILE" ]; then
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
    else
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
        export FILES_APP_ENABLED="yes"
        export GALLERY_APP_ENABLED="yes"
        export MUSIC_APP_ENABLED="yes"
        export CALENDAR_APP_ENABLED="yes"
        export CALCULATOR_APP_ENABLED="yes"
        export CONTACTS_APP_ENABLED="yes"
        export DESKCLOCK_APP_ENABLED="yes"
        export HDR_ENABLED="no"
        export DESKTOP_MODE_ENABLED="yes"
    fi
}

show_settings_summary() {
    echo -e "${CYAN}Current Build Settings:${NC}"
    echo "  Build Variant:     $BUILD_VARIANT ($BUILD_TYPE)"
    echo "  Display:           ${DISPLAY_RESOLUTION:-auto} @ ${DISPLAY_DENSITY}dpi"
    echo "  Audio Output:      $AUDIO_OUTPUT_DEVICE ($HDMI_AUDIO_PORT)"
    echo "  WiFi Country:      $WIFI_COUNTRY_CODE"
    echo "  UART Console:      $UART_DEVICE @ ${UART_BAUD_RATE}bps"
    echo "  Root Access:       $ROOT_ACCESS_ENABLED"
    echo "  SELinux:           $SELINUX_MODE"
    echo "  Partitions:        boot=${PARTITION_BOOT_MB}MB sys=${PARTITION_SYSTEM_MB}MB"
    echo ""
}

show_all_settings() {
    print_section "Build Configuration (from settings.conf)"

    echo -e "${YELLOW}BUILD VARIANT:${NC}"
    echo "  BUILD_VARIANT=$BUILD_VARIANT"
    echo "  BUILD_TYPE=$BUILD_TYPE"
    echo ""
    echo -e "${YELLOW}DISPLAY:${NC}"
    echo "  DISPLAY_DENSITY=$DISPLAY_DENSITY"
    echo "  DISPLAY_RESOLUTION=$DISPLAY_RESOLUTION"
    echo "  SCREEN_BRIGHTNESS_DEFAULT=$SCREEN_BRIGHTNESS_DEFAULT"
    echo "  NIGHT_MODE=$NIGHT_MODE"
    echo ""
    echo -e "${YELLOW}AUDIO:${NC}"
    echo "  AUDIO_OUTPUT_DEVICE=$AUDIO_OUTPUT_DEVICE"
    echo "  HDMI_AUDIO_PORT=$HDMI_AUDIO_PORT"
    echo "  MEDIA_VOLUME_DEFAULT=$MEDIA_VOLUME_DEFAULT"
    echo ""
    echo -e "${YELLOW}NETWORK:${NC}"
    echo "  WIFI_COUNTRY_CODE=$WIFI_COUNTRY_CODE"
    echo "  WIFI_5GHZ_ENABLED=$WIFI_5GHZ_ENABLED"
    echo "  BLUETOOTH_ENABLED=$BLUETOOTH_ENABLED"
    echo ""
    echo -e "${YELLOW}HDMI CEC:${NC}"
    echo "  HDMI_CEC_ENABLED=$HDMI_CEC_ENABLED"
    echo "  HDMI_CEC_DEVICE=$HDMI_CEC_DEVICE"
    echo ""
    echo -e "${YELLOW}UART CONSOLE:${NC}"
    echo "  UART_CONSOLE_ENABLED=$UART_CONSOLE_ENABLED"
    echo "  UART_DEVICE=$UART_DEVICE"
    echo "  UART_BAUD_RATE=$UART_BAUD_RATE"
    echo ""
    echo -e "${YELLOW}DEVELOPMENT:${NC}"
    echo "  ROOT_ACCESS_ENABLED=$ROOT_ACCESS_ENABLED"
    echo "  ADB_ROOT_ENABLED=$ADB_ROOT_ENABLED"
    echo "  SSH_ENABLED=$SSH_ENABLED"
    echo "  SELINUX_MODE=$SELINUX_MODE"
    echo ""
    echo -e "${YELLOW}PARTITIONS:${NC}"
    echo "  PARTITION_BOOT_MB=$PARTITION_BOOT_MB"
    echo "  PARTITION_SYSTEM_MB=$PARTITION_SYSTEM_MB"
    echo "  PARTITION_VENDOR_MB=$PARTITION_VENDOR_MB"
    echo "  PARTITION_USERDATA_MB=$PARTITION_USERDATA_MB"
    echo ""
    echo -e "${YELLOW}DEVICE:${NC}"
    echo "  DEVICE_NAME=$DEVICE_NAME"
    echo "  DEVICE_SERIAL=$DEVICE_SERIAL"
    echo ""
    if [ "$BUILD_VARIANT" = "car" ]; then
        echo -e "${YELLOW}CAR-SPECIFIC:${NC}"
        echo "  CAR_EVS_ENABLED=$CAR_EVS_ENABLED"
        echo "  CAR_CAN_ENABLED=$CAR_CAN_ENABLED"
        echo ""
    fi
    echo -e "${YELLOW}INCLUDED APPS:${NC}"
    echo "  FILES_APP_ENABLED=$FILES_APP_ENABLED (DocumentsUI/Files)"
    echo "  GALLERY_APP_ENABLED=$GALLERY_APP_ENABLED"
    echo "  MUSIC_APP_ENABLED=$MUSIC_APP_ENABLED"
    echo "  CALENDAR_APP_ENABLED=$CALENDAR_APP_ENABLED"
    echo "  CALCULATOR_APP_ENABLED=$CALCULATOR_APP_ENABLED"
    echo "  CONTACTS_APP_ENABLED=$CONTACTS_APP_ENABLED"
    echo "  DESKCLOCK_APP_ENABLED=$DESKCLOCK_APP_ENABLED"
    echo ""
    echo -e "${CYAN}Settings file: $SCRIPT_DIR/settings.conf${NC}"
}

edit_settings() {
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
        show_settings_summary
    else
        echo -e "${RED}Settings file not found: $SETTINGS_FILE${NC}"
    fi
}

# ===========================================
# PHASE 1: SETUP BUILD ENVIRONMENT
# ===========================================
install_dependencies() {
    echo -e "${YELLOW}Installing build dependencies...${NC}"

    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        sudo apt-get update
        sudo apt-get install -y \
            git-core gnupg flex bison gperf build-essential \
            zip curl zlib1g-dev gcc-multilib g++-multilib \
            libc6-dev-i386 libncurses5 lib32ncurses5-dev \
            x11proto-core-dev libx11-dev lib32z1-dev \
            ccache libgl1-mesa-dev libxml2-utils xsltproc \
            unzip fontconfig openjdk-17-jdk python3 python3-pip \
            libssl-dev bc cpio rsync lz4 wget \
            repo android-sdk-libsparse-utils \
            libncurses5-dev libncursesw5-dev \
            imagemagick schedtool

    elif [[ "$OS" == "fedora" ]]; then
        sudo dnf install -y \
            git gnupg flex bison gperf gcc gcc-c++ \
            zip curl zlib-devel ncurses-devel ncurses-compat-libs \
            libX11-devel ccache mesa-libGL-devel libxml2 \
            xsltproc unzip fontconfig java-17-openjdk java-17-openjdk-devel \
            python3 python3-pip openssl-devel bc cpio rsync lz4 wget \
            glibc-devel.i686 libstdc++-devel.i686 ncurses-devel.i686 \
            zlib-devel.i686 ImageMagick schedtool \
            android-tools

        # Install repo tool on Fedora
        if ! command -v repo &> /dev/null; then
            mkdir -p ~/.local/bin
            curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.local/bin/repo
            chmod a+x ~/.local/bin/repo
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
            export PATH="$HOME/.local/bin:$PATH"
        fi
    else
        echo -e "${RED}Unsupported OS: $OS${NC}"
        exit 1
    fi
}

configure_git() {
    echo -e "${YELLOW}Configuring git...${NC}"

    if [ -z "$(git config --global user.email)" ]; then
        read -p "Enter your email for git: " git_email
        git config --global user.email "$git_email"
    fi

    if [ -z "$(git config --global user.name)" ]; then
        read -p "Enter your name for git: " git_name
        git config --global user.name "$git_name"
    fi

    # Increase git buffer size for large repos
    git config --global http.postBuffer 1048576000
    git config --global color.ui auto
}

setup_ccache() {
    echo -e "${YELLOW}Setting up ccache...${NC}"

    # Set ccache size
    ccache -M ${CCACHE_SIZE_GB:-50}G

    # Add ccache to environment
    if ! grep -q "USE_CCACHE" ~/.bashrc; then
        echo '' >> ~/.bashrc
        echo '# AOSP Build Environment' >> ~/.bashrc
        echo 'export USE_CCACHE=1' >> ~/.bashrc
        echo 'export CCACHE_EXEC=/usr/bin/ccache' >> ~/.bashrc
        echo 'export CCACHE_DIR=~/.ccache' >> ~/.bashrc
    fi

    export USE_CCACHE=1
    export CCACHE_EXEC=/usr/bin/ccache
}

increase_limits() {
    echo -e "${YELLOW}Increasing system limits for build...${NC}"

    # Check if limits already set
    if ! grep -q "# AOSP Build Limits" /etc/security/limits.conf 2>/dev/null; then
        echo "Adding file descriptor limits..."
        sudo bash -c 'cat >> /etc/security/limits.conf << EOF

# AOSP Build Limits
* soft nofile 65536
* hard nofile 65536
EOF'
    fi

    # Increase inotify watches
    if ! grep -q "fs.inotify.max_user_watches" /etc/sysctl.conf 2>/dev/null; then
        sudo bash -c 'echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf'
        sudo sysctl -p
    fi
}

create_directories() {
    echo -e "${YELLOW}Creating build directories...${NC}"

    mkdir -p "$BUILD_DIR"

    echo -e "${GREEN}Build directory created at: $BUILD_DIR${NC}"
    echo "$BUILD_DIR" > "$SCRIPT_DIR/.build_dir"
}

setup_build_environment() {
    print_section "Phase 1: Setup Build Environment"

    detect_os
    echo -e "${GREEN}Detected OS: $OS $VER${NC}"
    echo ""
    echo "This will install AOSP build dependencies."
    echo "It requires sudo access for package installation."
    echo ""
    read -p "Continue? (y/n) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 1
    fi

    install_dependencies
    configure_git
    setup_ccache
    increase_limits
    create_directories

    echo ""
    echo -e "${GREEN}Build environment setup complete!${NC}"
    echo ""
    echo "Note: Log out and log back in (or run: source ~/.bashrc)"
    echo "Build directory: $BUILD_DIR"
}

# ===========================================
# PHASE 2: SYNC AOSP SOURCES
# ===========================================
sync_aosp_sources() {
    print_section "Phase 2: Sync AOSP Sources"

    echo "Build directory: $BUILD_DIR"
    echo ""
    echo -e "${YELLOW}This will download ~50-100GB of source code.${NC}"
    echo "Make sure you have enough disk space and a stable internet connection."
    echo ""
    read -p "Continue? (y/n) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 1
    fi

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

    # Copy custom manifests (root/SSH, TWRP recovery)
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
    echo -e "${GREEN}Source sync complete!${NC}"
}

# ===========================================
# PHASE 3: BUILD AAOS
# ===========================================
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

        # Display settings - density is set in BoardConfig.mk (TARGET_SCREEN_DENSITY)
        cat >> "$PROP_FILE" << EOF
# Display settings - density is set in BoardConfig.mk (TARGET_SCREEN_DENSITY)

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
        echo "BOARD_BOOTIMAGE_PARTITION_SIZE := $BOOT_SIZE" >> "$BOARD_CONFIG"
        echo "BOARD_SYSTEMIMAGE_PARTITION_SIZE := $SYSTEM_SIZE" >> "$BOARD_CONFIG"
        echo "BOARD_VENDORIMAGE_PARTITION_SIZE := $VENDOR_SIZE" >> "$BOARD_CONFIG"
        echo "BOARD_USERDATAIMAGE_PARTITION_SIZE := $USERDATA_SIZE" >> "$BOARD_CONFIG"

        echo -e "${GREEN}Partition sizes: boot=${PARTITION_BOOT_MB}MB sys=${PARTITION_SYSTEM_MB}MB vendor=${PARTITION_VENDOR_MB}MB data=${PARTITION_USERDATA_MB}MB${NC}"
    fi
}

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
        fi

        echo -e "${GREEN}SELinux ($SELINUX_MODE) and UART ($UART_DEVICE) configured.${NC}"
    fi
}

setup_ssh() {
    echo -e "${YELLOW}Configuring SSH support...${NC}"

    if [ -d "device/brcm/rpi5" ] && [ -f "device/brcm/rpi5/device.mk" ]; then
        # Remove any previously added broken SSH package entries
        if grep -q "# SSH Server packages" device/brcm/rpi5/device.mk; then
            echo -e "${YELLOW}Removing broken SSH package entries from device.mk...${NC}"
            sed -i '/# SSH Server packages/,/^$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*scp[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*sftp[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*ssh[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*sshd[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*ssh-keygen[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*sshd_config[[:space:]]*\\*$/d' device/brcm/rpi5/device.mk
            sed -i '/^[[:space:]]*start-ssh[[:space:]]*$/d' device/brcm/rpi5/device.mk
        fi

        echo -e "${YELLOW}Note: Native SSH requires custom build configuration.${NC}"
        echo -e "${YELLOW}For now, use 'adb shell' for root access.${NC}"
        echo -e "${GREEN}SSH configuration check complete.${NC}"
    else
        echo -e "${YELLOW}Device tree not ready.${NC}"
    fi
}

configure_apps() {
    echo -e "${YELLOW}Configuring included apps from settings.conf...${NC}"

    if [ -d "device/brcm/rpi5" ]; then
        DEVICE_MK="device/brcm/rpi5/device.mk"

        # Remove any previous app configuration block
        if [ -f "$DEVICE_MK" ] && grep -q "# Included Apps (from settings.conf)" "$DEVICE_MK"; then
            sed -i '/# Included Apps (from settings.conf)/,/^$/d' "$DEVICE_MK"
        fi

        # Build list of apps and their package names for launcher visibility
        APPS_LIST=""
        PACKAGE_LIST=""

        # DocumentsUI (Files app) - provides file browsing and document access
        if [ "$FILES_APP_ENABLED" = "yes" ]; then
            APPS_LIST="$APPS_LIST DocumentsUI"
            PACKAGE_LIST="$PACKAGE_LIST com.android.documentsui"
            echo -e "${GREEN}  + DocumentsUI (Files app)${NC}"
        fi

        # Gallery app
        if [ "$GALLERY_APP_ENABLED" = "yes" ]; then
            APPS_LIST="$APPS_LIST Gallery2"
            PACKAGE_LIST="$PACKAGE_LIST com.android.gallery3d"
            echo -e "${GREEN}  + Gallery2 (Gallery app)${NC}"
        fi

        # Music app
        if [ "$MUSIC_APP_ENABLED" = "yes" ]; then
            APPS_LIST="$APPS_LIST Music"
            PACKAGE_LIST="$PACKAGE_LIST com.android.music"
            echo -e "${GREEN}  + Music${NC}"
        fi

        # Calendar app
        if [ "$CALENDAR_APP_ENABLED" = "yes" ]; then
            APPS_LIST="$APPS_LIST Calendar"
            PACKAGE_LIST="$PACKAGE_LIST com.android.calendar"
            echo -e "${GREEN}  + Calendar${NC}"
        fi

        # Calculator app - removed, not available in Android 16
        # if [ "$CALCULATOR_APP_ENABLED" = "yes" ]; then
        #     APPS_LIST="$APPS_LIST ExactCalculator"
        #     PACKAGE_LIST="$PACKAGE_LIST com.android.calculator2"
        #     echo -e "${GREEN}  + ExactCalculator (Calculator app)${NC}"
        # fi

        # Contacts app
        if [ "$CONTACTS_APP_ENABLED" = "yes" ]; then
            APPS_LIST="$APPS_LIST Contacts"
            PACKAGE_LIST="$PACKAGE_LIST com.android.contacts"
            echo -e "${GREEN}  + Contacts${NC}"
        fi

        # DeskClock app (alarm, timer, stopwatch)
        if [ "$DESKCLOCK_APP_ENABLED" = "yes" ]; then
            APPS_LIST="$APPS_LIST DeskClock"
            PACKAGE_LIST="$PACKAGE_LIST com.android.deskclock"
            echo -e "${GREEN}  + DeskClock (Clock/Alarm app)${NC}"
        fi

        # Add apps to device.mk if any are enabled
        if [ -n "$APPS_LIST" ]; then
            echo "" >> "$DEVICE_MK"
            echo "# Included Apps (from settings.conf)" >> "$DEVICE_MK"
            echo "PRODUCT_PACKAGES += \\" >> "$DEVICE_MK"

            # Convert space-separated list to line-separated with backslashes
            FIRST=true
            for app in $APPS_LIST; do
                if [ "$FIRST" = true ]; then
                    echo "    $app \\" >> "$DEVICE_MK"
                    FIRST=false
                else
                    echo "    $app \\" >> "$DEVICE_MK"
                fi
            done

            # Remove trailing backslash from last line
            sed -i '$ s/ \\$//' "$DEVICE_MK"

            echo "" >> "$DEVICE_MK"
            echo -e "${GREEN}Apps configured in device.mk${NC}"

            # Configure car launcher overlay to show these apps
            configure_launcher_visibility "$PACKAGE_LIST"
        else
            echo -e "${YELLOW}No apps enabled in settings.conf${NC}"
        fi
    else
        echo -e "${YELLOW}Device tree not ready. Apps will be configured after sync.${NC}"
    fi
}

configure_launcher_visibility() {
    local PACKAGES="$1"
    echo -e "${YELLOW}Configuring car launcher to show included apps...${NC}"

    # Create overlay directory structure in device tree
    OVERLAY_DIR="device/brcm/rpi5/overlay/packages/apps/Car/Launcher/res/values"
    mkdir -p "$OVERLAY_DIR"

    # Generate car launcher config overlay with allowed packages
    cat > "$OVERLAY_DIR/config.xml" << 'LAUNCHER_XML'
<?xml version="1.0" encoding="utf-8"?>
<!--
    Car Launcher configuration overlay for AAOS Raspberry Pi 5
    Ensures AOSP apps appear in the car launcher app grid.
    Generated by AAOS build system - configure via settings.conf
-->
<resources>
    <!-- Don't hide any app launchers -->
    <string-array name="config_appLaunchersToHide" translatable="false">
    </string-array>

    <!-- Show all apps, not just automotive-certified ones -->
    <bool name="config_showAllApps">true</bool>

    <!-- Don't filter apps based on automotive metadata -->
    <bool name="config_filterNonAutomotiveApps">false</bool>
</resources>
LAUNCHER_XML

    # Create sysconfig to prevent hiding apps
    SYSCONFIG_DIR="device/brcm/rpi5/overlay/product/etc/sysconfig"
    mkdir -p "$SYSCONFIG_DIR"

    cat > "$SYSCONFIG_DIR/allowed-apps.xml" << 'SYSCONFIG_XML'
<?xml version="1.0" encoding="utf-8"?>
<!--
    System configuration to ensure apps are visible in AAOS launcher.
    Generated by AAOS build system.
-->
<config>
    <!-- Allow these apps to appear in the launcher -->
    <allow-in-data-usage-save package="com.android.documentsui" />
    <allow-in-data-usage-save package="com.android.gallery3d" />
    <allow-in-data-usage-save package="com.android.music" />
    <allow-in-data-usage-save package="com.android.calendar" />
    <allow-in-data-usage-save package="com.android.calculator2" />
    <allow-in-data-usage-save package="com.android.contacts" />
    <allow-in-data-usage-save package="com.android.deskclock" />

    <!-- Ensure these system apps are not disabled -->
    <system-user-whitelisted-app package="com.android.documentsui" />
    <system-user-whitelisted-app package="com.android.gallery3d" />
    <system-user-whitelisted-app package="com.android.music" />
    <system-user-whitelisted-app package="com.android.calendar" />
    <system-user-whitelisted-app package="com.android.calculator2" />
    <system-user-whitelisted-app package="com.android.contacts" />
    <system-user-whitelisted-app package="com.android.deskclock" />
</config>
SYSCONFIG_XML

    # Add overlay to device.mk if not already present
    DEVICE_MK="device/brcm/rpi5/device.mk"
    if ! grep -q "Car Launcher overlay" "$DEVICE_MK" 2>/dev/null; then
        echo "" >> "$DEVICE_MK"
        echo "# Car Launcher overlay to show all apps" >> "$DEVICE_MK"
        echo "DEVICE_PACKAGE_OVERLAYS += device/brcm/rpi5/overlay" >> "$DEVICE_MK"
        echo "" >> "$DEVICE_MK"
        echo "# Sysconfig for app visibility" >> "$DEVICE_MK"
        echo "PRODUCT_COPY_FILES += \\" >> "$DEVICE_MK"
        echo "    device/brcm/rpi5/overlay/product/etc/sysconfig/allowed-apps.xml:\$(TARGET_COPY_OUT_PRODUCT)/etc/sysconfig/allowed-apps.xml" >> "$DEVICE_MK"
        echo "" >> "$DEVICE_MK"
    fi

    echo -e "${GREEN}Car launcher configured to show all included apps${NC}"
}

run_build() {
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
    show_settings_summary

    # Source build environment
    source build/envsetup.sh

    # Select target based on settings
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

    # Build AAOS
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
}

build_aaos() {
    print_section "Phase 3: Build AAOS"

    if [ ! -d "$BUILD_DIR/.repo" ]; then
        echo -e "${RED}Error: AOSP source not found. Run sync first.${NC}"
        return 1
    fi

    cd "$BUILD_DIR"

    show_settings_summary

    echo "Build Options:"
    echo "  1) Apply overlays only (configure source tree)"
    echo "  2) Full build (apply overlays + build)"
    echo "  3) Resume build (just run make)"
    echo "  4) Clean build (make clean + full build)"
    echo ""
    read -p "Select option [2]: " option
    option=${option:-2}

    case $option in
        1)
            apply_overlays
            configure_root_access
            configure_partitions
            configure_selinux
            setup_ssh
            configure_apps
            echo -e "${GREEN}Overlays applied. Select option 2 or 3 to build.${NC}"
            ;;
        2)
            apply_overlays
            configure_root_access
            configure_partitions
            configure_selinux
            setup_ssh
            configure_apps
            run_build
            ;;
        3)
            run_build
            ;;
        4)
            source build/envsetup.sh
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
            configure_apps
            run_build
            ;;
        *)
            echo "Invalid option"
            return 1
            ;;
    esac
}

# ===========================================
# PHASE 4: BUILD TWRP RECOVERY
# ===========================================
build_twrp() {
    print_section "Phase 4: TWRP Recovery"

    echo "TWRP is now integrated into the main AAOS build."
    echo ""
    echo "Options:"
    echo "  1) Rebuild recovery image only (requires completed AAOS build)"
    echo "  2) Check recovery image status"
    echo "  3) Show pre-built TWRP download links (alternative)"
    echo ""
    read -p "Select option [2]: " option
    option=${option:-2}

    case $option in
        1)
            echo -e "${YELLOW}Rebuilding TWRP recovery image...${NC}"

            if [ ! -d "$BUILD_DIR/.repo" ]; then
                echo -e "${RED}Error: AOSP source not found. Run sync_aosp.sh first.${NC}"
                return 1
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
            check_recovery_status
            ;;
        2)
            check_recovery_status
            ;;
        3)
            echo ""
            echo "Pre-built TWRP is available as an alternative from KonstaKANG:"
            echo ""
            echo "  https://konstakang.com/devices/rpi5/TWRP/"
            echo ""
            echo "However, TWRP is now built automatically with the AAOS build."
            echo "Use pre-built only if you encounter build issues."
            ;;
        *)
            echo "Invalid option"
            return 1
            ;;
    esac
}

check_recovery_status() {
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
    echo "The recovery image is automatically included when you flash to SD card."
}

# ===========================================
# PHASE 5: FLASH SD CARD
# ===========================================
flash_sdcard() {
    print_section "Phase 5: Flash SD Card"

    echo "Available devices:"
    lsblk -d -o NAME,SIZE,MODEL | grep -E "^sd|^mmcblk" || echo "  No removable devices found"
    echo ""
    echo -e "${YELLOW}WARNING: Select the correct device! Wrong selection will destroy data.${NC}"
    echo ""
    read -p "Enter device path (e.g., /dev/sdb): " DEVICE

    if [ -z "$DEVICE" ]; then
        echo "No device specified. Aborted."
        return 1
    fi

    # Safety checks
    if [ ! -b "$DEVICE" ]; then
        echo -e "${RED}Error: $DEVICE is not a valid block device.${NC}"
        return 1
    fi

    # Prevent flashing to system drive
    if mount | grep -q "^$DEVICE"; then
        MOUNT_POINT=$(mount | grep "^$DEVICE" | awk '{print $3}')
        if [ "$MOUNT_POINT" = "/" ] || [ "$MOUNT_POINT" = "/home" ] || [ "$MOUNT_POINT" = "/boot" ]; then
            echo -e "${RED}Error: Cannot flash to mounted system partition!${NC}"
            return 1
        fi
    fi

    # Check for image
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
        return 1
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
        return 0
    fi

    # Unmount all partitions
    echo -e "${YELLOW}Unmounting partitions...${NC}"
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

    if [[ "$DEVICE" =~ [0-9]$ ]]; then
        BOOT_PART="${DEVICE}p1"
    else
        BOOT_PART="${DEVICE}1"
    fi

    if [ -b "$BOOT_PART" ]; then
        BOOT_MOUNT=$(mktemp -d)
        sudo mount "$BOOT_PART" "$BOOT_MOUNT" 2>/dev/null || true

        if [ -f "$BOOT_MOUNT/config.txt" ]; then
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
    echo "  - UART: Physical pins 8 (TX) / 10 (RX) at 115200 baud"
    echo ""
    echo "TWRP Recovery:"
    echo "  - Boot to recovery: adb reboot recovery"
}

# ===========================================
# FULL SETUP (ALL PHASES)
# ===========================================
full_setup() {
    print_section "Full Setup: Environment → Sync → Build → Flash"

    echo "This will run all phases sequentially:"
    echo "  1. Setup build environment"
    echo "  2. Sync AOSP sources (~50-100GB download)"
    echo "  3. Build AAOS (4-8+ hours)"
    echo "  4. Flash to SD card"
    echo ""
    echo -e "${YELLOW}Requirements:${NC}"
    echo "  - ~300GB free disk space"
    echo "  - 16GB+ RAM recommended"
    echo "  - Stable internet connection"
    echo "  - Several hours of build time"
    echo ""
    read -p "Continue with full setup? (y/n) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 1
    fi

    # Phase 1: Setup
    setup_build_environment || return 1
    press_enter_to_continue

    # Phase 2: Sync
    sync_aosp_sources || return 1
    press_enter_to_continue

    # Phase 3: Build
    cd "$BUILD_DIR"
    apply_overlays
    configure_root_access
    configure_partitions
    configure_selinux
    setup_ssh
    configure_apps
    run_build || return 1
    press_enter_to_continue

    # Phase 4: Flash
    flash_sdcard

    echo ""
    echo -e "${GREEN}Full setup complete!${NC}"
}

# ===========================================
# STATUS CHECK
# ===========================================
check_status() {
    print_section "Build Status"

    echo -e "${CYAN}Environment:${NC}"
    echo "  Script directory: $SCRIPT_DIR"
    echo "  Build directory:  $BUILD_DIR"
    echo ""

    # Check environment setup
    if command -v repo &> /dev/null; then
        echo -e "${GREEN}  ✓ repo tool installed${NC}"
    else
        echo -e "${RED}  ✗ repo tool not installed${NC}"
    fi

    if [ -f ~/.bashrc ] && grep -q "USE_CCACHE" ~/.bashrc; then
        echo -e "${GREEN}  ✓ ccache configured${NC}"
    else
        echo -e "${YELLOW}  ○ ccache not configured${NC}"
    fi

    echo ""
    echo -e "${CYAN}Source Code:${NC}"
    if [ -d "$BUILD_DIR/.repo" ]; then
        echo -e "${GREEN}  ✓ AOSP repository initialized${NC}"
        if [ -d "$BUILD_DIR/device/brcm/rpi5" ]; then
            echo -e "${GREEN}  ✓ Raspberry Pi 5 device tree present${NC}"
        else
            echo -e "${YELLOW}  ○ Device tree not synced${NC}"
        fi
    else
        echo -e "${RED}  ✗ AOSP repository not initialized${NC}"
    fi

    echo ""
    echo -e "${CYAN}Build Output:${NC}"
    if [ -d "$PRODUCT_DIR" ]; then
        # Check for images
        VANILLA_IMG=$(ls -t "$PRODUCT_DIR"/RaspberryVanillaAOSP16-*.img 2>/dev/null | head -1)
        if [ -n "$VANILLA_IMG" ] && [ -f "$VANILLA_IMG" ]; then
            SIZE=$(du -h "$VANILLA_IMG" | cut -f1)
            echo -e "${GREEN}  ✓ Flashable image: $(basename $VANILLA_IMG) ($SIZE)${NC}"
        elif [ -f "$PRODUCT_DIR/rpi5.img" ]; then
            SIZE=$(du -h "$PRODUCT_DIR/rpi5.img" | cut -f1)
            echo -e "${GREEN}  ✓ Flashable image: rpi5.img ($SIZE)${NC}"
        else
            echo -e "${YELLOW}  ○ No flashable image found${NC}"
        fi

        if [ -f "$PRODUCT_DIR/recovery.img" ]; then
            SIZE=$(du -h "$PRODUCT_DIR/recovery.img" | cut -f1)
            echo -e "${GREEN}  ✓ Recovery image: recovery.img ($SIZE)${NC}"
        else
            echo -e "${YELLOW}  ○ No recovery image found${NC}"
        fi
    else
        echo -e "${RED}  ✗ No build output directory${NC}"
    fi

    echo ""
    show_settings_summary
}

# ===========================================
# MAIN MENU
# ===========================================
show_main_menu() {
    print_header

    echo "Build directory: $BUILD_DIR"
    echo ""

    echo -e "${BOLD}Main Menu:${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Full Setup (Environment → Sync → Build → Flash)"
    echo ""
    echo -e "  ${CYAN}2)${NC} Setup Build Environment"
    echo -e "  ${CYAN}3)${NC} Sync AOSP Sources"
    echo -e "  ${CYAN}4)${NC} Build AAOS"
    echo -e "  ${CYAN}5)${NC} Build TWRP Recovery"
    echo -e "  ${CYAN}6)${NC} Flash SD Card"
    echo ""
    echo -e "  ${CYAN}7)${NC} Configure Settings"
    echo -e "  ${CYAN}8)${NC} Show All Settings"
    echo -e "  ${CYAN}9)${NC} Check Status"
    echo ""
    echo -e "  ${CYAN}0)${NC} Exit"
    echo ""
    read -p "Select option: " choice

    case $choice in
        1) full_setup ;;
        2) setup_build_environment ;;
        3) sync_aosp_sources ;;
        4) build_aaos ;;
        5) build_twrp ;;
        6) flash_sdcard ;;
        7) edit_settings ;;
        8) show_all_settings ;;
        9) check_status ;;
        0)
            echo "Goodbye!"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac

    press_enter_to_continue
}

# ===========================================
# COMMAND LINE INTERFACE
# ===========================================
show_help() {
    echo "AAOS All-In-One Build Tool v${VERSION}"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  (none)      Interactive menu mode"
    echo "  setup       Setup build environment"
    echo "  sync        Sync AOSP sources"
    echo "  build       Build AAOS"
    echo "  twrp        Build TWRP recovery"
    echo "  flash       Flash SD card"
    echo "  status      Check build status"
    echo "  settings    Edit settings"
    echo "  full        Run full setup (all phases)"
    echo "  help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0              # Interactive menu"
    echo "  $0 setup        # Setup build environment"
    echo "  $0 build        # Build AAOS"
    echo "  $0 flash        # Flash to SD card"
}

# ===========================================
# MAIN ENTRY POINT
# ===========================================
main() {
    check_not_root
    load_settings

    # Handle command line arguments
    case "${1:-}" in
        setup)
            setup_build_environment
            ;;
        sync)
            sync_aosp_sources
            ;;
        build)
            build_aaos
            ;;
        twrp)
            build_twrp
            ;;
        flash)
            flash_sdcard
            ;;
        status)
            check_status
            ;;
        settings)
            edit_settings
            ;;
        full)
            full_setup
            ;;
        help|--help|-h)
            show_help
            ;;
        "")
            # Interactive menu mode
            while true; do
                show_main_menu
            done
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
