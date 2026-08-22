# Project TODO / Deferred Work

Items intentionally deferred in the 2026-04-09 session. Each entry has
enough context that a future session (or a future me) can pick it up
without re-researching.

## 1. Userdata auto-resize on first boot

**Status:** deferred — "leave as is" for now (2026-04-09).

**Problem:** `device/brcm/rpi{4,5}/mkimg.sh` hardcodes a 15.36 GB output
image with userdata fixed at ~11.7 GB. Regardless of whether you flash
to a 16 GB or a 256 GB SD card, userdata stays 11.7 GB — the rest of
the card is permanently unused.

**What we want:** ship a small ~4 GB image, and on first boot (or
every boot, idempotently) expand partition 3 to fill the SD card and
`resize2fs` the ext4 filesystem to match. Same one image flashes to
any card ≥ 4 GB.

**Why raspberry-vanilla doesn't do it:** no first-boot resize hook
exists in their init.rc, and no partition-table editor ships in AOSP.
The standard Raspberry Pi OS `init_resize.sh` path doesn't apply —
Android boots via its own init, not `/sbin/init` + systemd.

**Implementation sketch (≈190 lines total):**

1. Patch `device/brcm/rpi{4,5}/mkimg.sh`:
   ```bash
   IMGSIZE=4200000000           # ~4.2 GB
   USERDATA_PARTITION_SIZE=256  # MB
   ```
2. New project `device/brcm/common/expand_userdata/`:
   - `expand_userdata.c` (~60 lines): open `/dev/block/mmcblk0`,
     `ioctl(BLKGETSIZE64)`, read MBR, rewrite partition-3 sector-count
     at offset `0x1EE+12`, `pwrite`, `fsync`, `ioctl(BLKRRPART)`.
     Idempotent — no-op if p3 already fills the disk.
   - `Android.bp`: `cc_binary { vendor: true }`.
3. New init fragment `init.expand_userdata.rc` (~8 lines):
   ```
   on fs
       exec - root root -- /vendor/bin/expand_userdata /dev/block/mmcblk0 3
       exec - root root -- /system/bin/resize2fs -f /dev/block/mmcblk0p3
   ```
   Runs before `on post-fs-data`, so userdata is not mounted yet.
4. `device/brcm/rpi{4,5}/device.mk`:
   `PRODUCT_PACKAGES += expand_userdata` and `PRODUCT_COPY_FILES +=
   init.expand_userdata.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/`.
5. Layer all the above into `overlays/expand_userdata/` and apply via
   `scripts/vm/apply-customizations.sh` so raspberry-vanilla source is
   never modified directly.

**Pros:** ~4 GB image (vs. 15.36 GB), single image fits any card ≥ 4 GB,
full-card userdata after first boot, faster extract/archive/flash.

**Cons:** ~190 lines of custom code + init logic to maintain; ~2-5 s
extra boot time on the first card-swap; bugs in the C tool can brick
an install (reflash recovery only); if raspberry-vanilla re-orgs
`mkimg.sh` our patch will need rebasing.

**Alternative (40 lines of bash) — host-side manual resize:**

A `scripts/expand-sdcard.sh /dev/diskN` that edits the partition table
on the host *before* first boot, using `diskutil` / `fdisk` on macOS.
No in-image changes, no AOSP build impact. Cost: user runs one more
command per flash. Good stepping stone if the full in-image path feels
like too much to maintain.

**Decision criteria for picking A vs B:** if we end up flashing many
SD cards of different sizes regularly (production fleet, test rig
rotation), do A. If we mostly flash the same card over and over,
sticking with the 15.36 GB fixed image is fine.

**References:**
- `reference/raspberry-vanilla/rpi{4,5}/mkimg.sh` — the script to patch
- Android MBR offsets: partition N entry at `0x1BE + (N-1)*16`,
  sector count at `entry+12..entry+15` (little-endian)
- `ioctl(BLKGETSIZE64)` — `linux/fs.h`
- `resize2fs` ships in AOSP `external/e2fsprogs`, output to
  `/system/bin/resize2fs`.

---

## 2. Dropbear SSH (real SSH, not adbd-TCP) — deferred

See `docs/ssh-root-access.md` for the sketch. Current MVP uses adbd
over TCP 5555 which is strictly better for troubleshooting. Revisit
only if we need real SSH for non-adb clients (e.g. rsync-over-ssh for
log collection from a headless Pi fleet).

---

## 3. Port `settings.conf` knobs from RPi_AAOS16

The old framework at `~/Downloads/GitHub/RPi_AAOS16/settings.conf`
has a bunch of useful build toggles we haven't brought over yet:

- `DISPLAY_DENSITY`, `DISPLAY_RESOLUTION`, `SCREEN_BRIGHTNESS_*`
- `AUDIO_OUTPUT_DEVICE`, `HDMI_AUDIO_PORT`, `MEDIA_VOLUME_*`
- `WIFI_COUNTRY_CODE`, `WIFI_HOTSPOT_SSID`, `BLUETOOTH_ENABLED`
- `HDMI_CEC_*`
- `USB_GADGET_MODE`, `USB_MANUFACTURER`, `USB_PRODUCT`
- `SKIP_SETUP_WIZARD`, `DISABLE_LOCKSCREEN`, `STAY_ON_WHILE_PLUGGED`
- `PARTITION_*_MB` overrides
- `CAR_EVS_CAMERA`, `CAR_CAN_ENABLED`

The current workspace bakes these as code in
`scripts/vm/apply-customizations.sh`. Worth generalising to a
`settings.conf`-style file in the project root if the set grows.

---

## 4. `reference/raspberry-vanilla/` upstream drift detection

The snapshot in `reference/raspberry-vanilla/` is pinned to whatever
was on `android-16.0` on 2026-04-09. When we bump the AOSP tag or
rebase, refresh the snapshot and `diff -r` against the previous one to
catch silent upstream changes (especially `BoardConfig.mk`, which
carries the kernel cmdline — any change to `console=` would break our
UART documentation without warning).

Refresh command in `reference/README.md`.

---

## 5. Socket_vmnet benefit — unproven

We installed socket_vmnet + shared networking but never A/B'd it
against plain slirp at matched parallelism. For future sessions:
before recommending more virtualization-layer work, run a controlled
test:

```
# slirp baseline: remove the networks: block from the instance yaml
# vmnet: current setup
# measure repo sync big-blob phase at -j32 for both, same network conditions
```

If vmnet shows no measurable benefit for repo sync's big-blob phase,
we can drop the complexity (rm /etc/sudoers.d/lima, leave
/opt/socket_vmnet alone).
