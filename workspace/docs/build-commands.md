# Build Commands — AAOS 16 for Pi 4 and Pi 5

Canonical commands as of 2026-04-09. These are what the numbered
scripts execute under the hood; documented here so you can run them
by hand inside the VM (`./scripts/vm-shell.sh`) when debugging.

## Prereqs (one-time)

```bash
# inside the Lima VM, user `zeno`
sudo apt-get install -y \
  git-core gnupg flex bison gperf build-essential \
  zip curl zlib1g-dev gcc-multilib g++-multilib \
  libc6-dev-i386 libncurses5 libncurses5-dev lib32ncurses5-dev \
  x11proto-core-dev libx11-dev lib32z1-dev ccache \
  libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig \
  openjdk-17-jdk python3 python3-pip python-is-python3 \
  libssl-dev bc cpio rsync lz4 wget \
  dosfstools e2fsprogs fdisk kpartx mtools \
  imagemagick schedtool android-sdk-libsparse-utils

curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
  -o /usr/local/bin/repo && sudo chmod a+x /usr/local/bin/repo

export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache
# CCACHE_DIR MUST be under out/: Soong's nsjail sandbox mounts / read-only
# and only grants RW to /tmp, the source tree and out/, so a cache in $HOME
# fails the build with "Read-only file system". Keep in sync with
# scripts/vm/build-aaos.sh. See docs/build-tuning-2026-04-13.md Q1.
export CCACHE_DIR=$HOME/aosp/out/.ccache CCACHE_COMPRESS=1
mkdir -p "$CCACHE_DIR"
ccache -M 200G
```

The Lima template already runs all of this via cloud-init.

## Repo init + sync

```bash
mkdir -p ~/aosp && cd ~/aosp

repo init \
  -u https://android.googlesource.com/platform/manifest \
  -b android-16.0.0_r4 \
  --partial-clone --clone-filter=blob:limit=10M

mkdir -p .repo/local_manifests
curl -fsSL \
  https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/android-16.0/manifest_brcm_rpi.xml \
  -o .repo/local_manifests/manifest_brcm_rpi.xml
curl -fsSL \
  https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/android-16.0/remove_projects.xml \
  -o .repo/local_manifests/remove_projects.xml

repo sync -c -j12 --force-sync --no-clone-bundle --no-tags --optimized-fetch
```

Expect 100–150 GB downloaded and 1–3 hours, dominated by network.

## Build — Pi 4 automotive

```bash
cd ~/aosp
source build/envsetup.sh
lunch aosp_rpi4_car-bp4a-userdebug
make bootimage systemimage vendorimage -j$(nproc)
./rpi4-mkimg.sh
```

Output: `~/aosp/RaspberryVanillaAOSP16-<DATE>-rpi4_car.img` (~8–15 GB)
plus `~/aosp/out/target/product/rpi4/{boot,system,vendor}.img`.

## Build — Pi 5 automotive

```bash
cd ~/aosp
source build/envsetup.sh
lunch aosp_rpi5_car-bp4a-userdebug
make bootimage systemimage vendorimage -j$(nproc)
./rpi5-mkimg.sh
```

Output: `~/aosp/RaspberryVanillaAOSP16-<DATE>-rpi5_car.img`.

ccache is shared between the two lunch targets, so building Pi 5
immediately after Pi 4 (or vice versa) is dramatically faster than
the first build.

## All six lunch targets

| Target                              | Board | Variant     |
|-------------------------------------|-------|-------------|
| `aosp_rpi4-bp4a-userdebug`          | Pi 4  | tablet      |
| `aosp_rpi4_tv-bp4a-userdebug`       | Pi 4  | Android TV  |
| `aosp_rpi4_car-bp4a-userdebug`      | Pi 4  | Automotive  |
| `aosp_rpi5-bp4a-userdebug`          | Pi 5  | tablet      |
| `aosp_rpi5_tv-bp4a-userdebug`       | Pi 5  | Android TV  |
| `aosp_rpi5_car-bp4a-userdebug`      | Pi 5  | Automotive  |

## Flashing to SD card

On macOS, after running `./scripts/04-extract-image.sh pi4` (or
`pi5`), the image is at `$AAOS_ROOT/out/RaspberryVanillaAOSP16-<date>-rpi{4,5}_car.img`.

Flash with Raspberry Pi Imager:
1. "Use custom" → pick the `.img`
2. Target: Raspberry Pi 4 or Pi 5, SD card ≥32 GB
3. No OS customisation (don't inject WiFi here — Android will manage it)
4. Write + verify

Or with `dd` (careful — double-check the target disk):

```bash
diskutil list                                  # find the SD card, e.g. /dev/disk6
diskutil unmountDisk /dev/disk6
sudo dd if=./out/RaspberryVanillaAOSP16-<date>-rpi4_car.img \
  of=/dev/rdisk6 bs=4m status=progress
diskutil eject /dev/disk6
```

## Rebuild after source tweaks

If you modify files under `device/brcm/rpi{4,5}` (e.g. via
`apply-customizations.sh`), a subsequent `make bootimage systemimage
vendorimage` picks them up — no `repo sync` needed. Only fetch new
upstream commits when you actually want to pull in updates:

```bash
cd ~/aosp
repo sync -c -j12 --force-sync --optimized-fetch
```

## Cleaning

```bash
cd ~/aosp
m clean            # full clean (rm -rf out/)
# or
m installclean     # keep intermediates, drop install-image outputs
```

ccache is preserved across `m clean`.
