#!/usr/bin/env bash
# vm/extract-image.sh pi4|pi5 — runs INSIDE the Lima VM.
#
# Copies the newest flashable .img for the given board to /mnt/out
# (which is $AAOS_ROOT/out on the macOS host).

set -euo pipefail

TARGET="${1:-}"
# Accept either short (pi4/pi5) or canonical (rpi4/rpi5) form; canonicalize.
case "$TARGET" in
  pi4|rpi4) BOARD=rpi4 ;;
  pi5|rpi5) BOARD=rpi5 ;;
  *) echo "Usage: $0 pi4|pi5   (or rpi4|rpi5)" >&2; exit 1 ;;
esac

AOSP_DIR="$HOME/aosp"

# mkimg.sh drops the flashable image at the top of the AOSP tree
# (e.g. RaspberryVanillaAOSP16-<DATE>-rpi5_car.img). Fall back to the
# product dir if not found.
mapfile -t CANDIDATES < <(
  ls -t "$AOSP_DIR"/RaspberryVanillaAOSP*"${BOARD}"*.img 2>/dev/null || true
  ls -t "$AOSP_DIR/out/target/product/${BOARD}/"*.img 2>/dev/null || true
)

[ "${#CANDIDATES[@]}" -gt 0 ] || { echo "no .img found for $BOARD"; exit 1; }

mkdir -p /mnt/out
IMG="${CANDIDATES[0]}"
echo "[extract] copying $IMG → /mnt/out/"
cp -f "$IMG" /mnt/out/

# Also copy the individual partition images for advanced flashing.
for p in boot system vendor; do
  SRC="$AOSP_DIR/out/target/product/${BOARD}/${p}.img"
  if [ -f "$SRC" ]; then
    DST="/mnt/out/${BOARD}-${p}.img"
    cp -f "$SRC" "$DST"
    echo "[extract]   + ${DST}"
  fi
done

ls -lh /mnt/out/ | head
