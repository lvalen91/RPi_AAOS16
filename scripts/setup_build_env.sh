#!/bin/bash
#
# AOSP Android 16 Automotive OS Build Environment Setup
# For Raspberry Pi 5 with TWRP, Root Access, SSH, and ADB Root
#
# This script sets up the build environment on Ubuntu/Debian-based systems
#

set -e

echo "=============================================="
echo "AAOS Build Environment Setup for Raspberry Pi 5"
echo "=============================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Please do not run this script as root. Run as regular user.${NC}"
    exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    echo -e "${RED}Cannot detect OS. This script supports Ubuntu/Debian/Fedora.${NC}"
    exit 1
fi

echo -e "${GREEN}Detected OS: $OS $VER${NC}"

# Install dependencies based on OS
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

# Configure git
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

# Set up ccache
setup_ccache() {
    echo -e "${YELLOW}Setting up ccache...${NC}"

    # Set ccache size to 50GB
    ccache -M 50G

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

# Increase file descriptor limits
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

# Create directory structure
create_directories() {
    echo -e "${YELLOW}Creating build directories...${NC}"

    # Get script directory for storing .build_dir
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    BUILD_DIR="$HOME/aosp-aaos-rpi5"
    mkdir -p "$BUILD_DIR"

    echo -e "${GREEN}Build directory created at: $BUILD_DIR${NC}"
    echo "$BUILD_DIR" > "$SCRIPT_DIR/.build_dir"
}

# Main execution
main() {
    echo ""
    echo "This script will install AOSP build dependencies."
    echo "It requires sudo access for package installation."
    echo ""
    read -p "Continue? (y/n) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    install_dependencies
    configure_git
    setup_ccache
    increase_limits
    create_directories

    echo ""
    echo -e "${GREEN}=============================================="
    echo "Build environment setup complete!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Log out and log back in (or run: source ~/.bashrc)"
    echo "  2. Run: ./sync_aosp.sh"
    echo ""
    echo "Build directory: $HOME/aosp-aaos-rpi5"
    echo -e "${NC}"
}

main "$@"
