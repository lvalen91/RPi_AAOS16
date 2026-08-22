#!/usr/bin/env bash
# patches/build_kernel_rpi4.sh <aosp-tree> [kernel-workdir]
#
# Build the Pi 4 kernel from source with the patches in kernel_brcm_rpi/, and
# install the result into <aosp-tree>/device/brcm/rpi4-kernel.
#
# WHY THIS EXISTS
#
# device/brcm/rpi4-kernel is a *prebuilt* — Image plus dtbs, no source. Anything
# that needs a kernel config change (CONFIG_BT_RFCOMM, for one) therefore needs
# an out-of-tree build, and cannot be done from the AOSP build alone.
#
# Upstream builds this with bazel/kleaf. We use plain make, which is far less
# setup. That was validated: at commit 8af794a959ec every dtb and all 367 dtbo
# overlays came out BYTE-IDENTICAL to the shipped prebuilts. Only Image differs,
# which is the point.
#
# TWO NON-OBVIOUS REQUIREMENTS
#
#  1. clang is mandatory, not optional: the defconfig sets CONFIG_CFI_CLANG=y and
#     CONFIG_SHADOW_CALL_STACK=y, neither of which gcc can build. We use the AOSP
#     tree's own clang prebuilt so no extra toolchain download is needed. Note
#     this will differ from the version upstream's builder used, and the version
#     string reflects it.
#
#  2. The defconfig compiles regulatory.db and the brcm firmware INTO the kernel
#     via CONFIG_EXTRA_FIRMWARE_DIR="../vendor/brcm/rpi4/proprietary/vendor/firmware"
#     — a path relative to the kernel source root. So vendor/brcm must sit as a
#     SIBLING of the kernel tree. We symlink it to the AOSP tree's copy. Without
#     this the build dies with "No rule to make target .../regulatory.db".
set -euo pipefail

AOSP="${1:-}"
WORK="${2:-$HOME/kernel}"
[ -n "$AOSP" ] || { echo "usage: $0 <aosp-tree> [kernel-workdir]" >&2; exit 1; }
[ -d "$AOSP/device/brcm/rpi4-kernel" ] || { echo "no rpi4-kernel in $AOSP" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$WORK/rpi"
# The commit the shipped 6.12.73-g8af794a959ec-v8 prebuilt was built from.
# Pinned deliberately: building at branch HEAD would add thousands of unrelated
# commits to a kernel that was just validated on hardware.
BASE_COMMIT="${KERNEL_BASE_COMMIT:-8af794a959ec}"

mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
  echo "== cloning raspberry-vanilla kernel (~5 GB)"
  git clone --branch android-16.0 --single-branch \
    https://github.com/raspberry-vanilla/android_kernel_brcm_rpi.git "$SRC"
fi

# See requirement 2 above.
ln -sfn "$AOSP/vendor" "$WORK/vendor"

cd "$SRC"
git fetch --all --quiet || true
git checkout -q -B rpi4-patched "$BASE_COMMIT"
for p in "$SCRIPT_DIR"/kernel_brcm_rpi/*.patch; do
  [ -e "$p" ] || continue
  echo "== applying $(basename "$p")"
  git am --quiet "$p" || { git am --abort || true; echo "patch failed: $p" >&2; exit 1; }
done

CLANG="$(ls -d "$AOSP"/prebuilts/clang/host/linux-x86/clang-r* 2>/dev/null | sort | tail -1)"
[ -n "$CLANG" ] || { echo "no clang prebuilt under $AOSP/prebuilts/clang" >&2; exit 1; }
export PATH="$CLANG/bin:$PATH"
echo "== toolchain: $(clang --version | head -1)"

make -s O=out ARCH=arm64 LLVM=1 android_rpi4_defconfig
grep -q '^CONFIG_BT_RFCOMM=y' out/.config || { echo "RFCOMM did not survive defconfig" >&2; exit 1; }
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 Image dtbs

# ---- install ----
K="$SRC/out/arch/arm64/boot"
D="$AOSP/device/brcm/rpi4-kernel"
cp -f "$K/Image" "$D/Image"
for dtb in bcm2711-rpi-4-b bcm2711-rpi-400 bcm2711-rpi-cm4 bcm2711-rpi-cm4-io bcm2711-rpi-cm4s; do
  cp -f "$K/dts/broadcom/$dtb.dtb" "$D/$dtb.dtb"
done
# Replace only overlays that already ship, so the shipped set does not change.
n=0
for f in "$D"/overlays/*.dtbo; do
  b="$(basename "$f")"
  [ -f "$K/dts/overlays/$b" ] && { cp -f "$K/dts/overlays/$b" "$f"; n=$((n+1)); }
done

echo "== installed into $D ($n overlays)"
strings -a "$D/Image" | grep -m1 "Linux version" || true
