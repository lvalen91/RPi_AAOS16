# `RPi_AAOS16` — Analysis of the user's existing framework

**Location:** `/Users/zeno/Downloads/GitHub/RPi_AAOS16`
**Captured:** 2026-04-09

The user showed me a prior build framework that was created in an
earlier session. It's a complete orchestration layer on top of
raspberry-vanilla, but it's **out of date and Pi 5-only**, so the new
project at `/Volumes/stuff/rpi/aaos` supersedes it. This doc records
what's in it and what we carried forward vs replaced.

## Contents

```
RPi_AAOS16/
├── aaos.sh                    52 KB — single-file all-in-one orchestrator
├── settings.conf              Build config knobs (display, audio, root, …)
├── scripts/
│   ├── setup_build_env.sh     Installs AOSP deps on Ubuntu/Debian/Fedora
│   ├── sync_aosp.sh           repo init + sync
│   ├── build_aaos.sh          Lunch + make + mkimg
│   ├── build_twrp.sh          TWRP recovery build
│   └── flash_sdcard.sh        SD-card imager
├── local_manifests/
│   ├── manifest_root_ssh.xml          (adds root/SSH support)
│   └── manifest_twrp.xml.disabled     (TWRP, off)
├── overlay/
│   ├── device/
│   ├── frameworks/
│   └── packages/
├── README.md                  "Compile from source AAOS" — stub
└── LICENSE
```

## Key pins (what the framework targets)

| | Framework (`RPi_AAOS16`) | Current upstream (Apr 2026) |
|---|---|---|
| AOSP branch | **`android-16.0.0_r3`** | **`android-16.0.0_r4`** |
| Lunch suffix | `bp2a` (inferred, pre-`_r4`) | **`bp4a`** |
| Target boards | Pi 5 only (`rpi5`, `$HOME/aosp-aaos-rpi5`, `out/target/product/rpi5`) | Pi 4 **and** Pi 5 |
| Host OS | Ubuntu/Debian/Fedora | Lima VM running Ubuntu 22.04 LTS |
| UART device setting | `UART_DEVICE="ttyAMA0"` (wrong for both boards) | Pi 4: ttyS0, Pi 5: ttyAMA10 (verified from BoardConfig.mk) |

## Notable `settings.conf` knobs

Good ideas worth keeping, some already covered by the new project:

- `BUILD_VARIANT=car/tablet/tv` — lunch-variant switch
- `BUILD_TYPE=userdebug|user|eng`
- `DISPLAY_RESOLUTION`, `DISPLAY_DENSITY`, `SCREEN_BRIGHTNESS_*`
- `AUDIO_OUTPUT_DEVICE`, `HDMI_AUDIO_PORT`
- `WIFI_COUNTRY_CODE`, `WIFI_HOTSPOT_SSID`, `BLUETOOTH_ENABLED`
- `HDMI_CEC_ENABLED`, `HDMI_CEC_DEVICE`
- `USB_GADGET_MODE`, `USB_MANUFACTURER`, `USB_PRODUCT`
- `UART_CONSOLE_ENABLED`, `UART_DEVICE`, `UART_BAUD_RATE`
  — **`UART_DEVICE="ttyAMA0"` is wrong for both Pi 4 and Pi 5**.
- `ROOT_ACCESS_ENABLED`, `ADB_ROOT_ENABLED`, `SSH_ENABLED`
- `SELINUX_MODE=permissive`
- `SKIP_SETUP_WIZARD`, `DISABLE_LOCKSCREEN`, `STAY_ON_WHILE_PLUGGED`
- `PARTITION_*_MB` overrides
- `CAR_EVS_ENABLED`, `CAR_EVS_CAMERA`, `CAR_CAN_ENABLED`

## Issues found

1. **AOSP tag drift** — pinned to `_r3`, upstream is `_r4` (Android 16 QPR2).
2. **Lunch suffix drift** — `bp2a` will fail for `_r4`; must be `bp4a`.
3. **Pi 5-only hardcoding** — `BUILD_DIR=$HOME/aosp-aaos-rpi5`,
   `PRODUCT_DIR=$BUILD_DIR/out/target/product/rpi5`. Switching to Pi 4
   would require touching every script.
4. **UART device wrong** — `settings.conf` says `UART_DEVICE="ttyAMA0"`.
   - Pi 4 uses `ttyS0` (mini UART on GPIO 14/15)
   - Pi 5 uses `ttyAMA10` (dedicated 3-pin JST SH debug header)
   - `ttyAMA0` would only be correct on Pi 4 *after* `dtoverlay=disable-bt`.
5. **macOS host incompatibility** — `setup_build_env.sh` detects
   Ubuntu/Debian/Fedora but errors on macOS. There's no Lima/VM
   story; user has to bring their own Linux box.
6. **Single-file 52 KB `aaos.sh`** — an all-in-one wrapper that
   duplicates the modular scripts. Hard to reason about and modify
   incrementally.
7. **`.DS_Store`** committed at repo root and inside `overlay/`.

## What carries forward to the new project

**From RPi_AAOS16 → `/Volumes/stuff/rpi/aaos`:**

| Concept | New location | Notes |
|---|---|---|
| Modular script layout       | `scripts/` + `scripts/vm/` | Split host-side and in-VM responsibilities |
| `settings.conf` config knobs | To be added as overlays | Not yet ported — current workflow uses in-script constants + `apply-customizations.sh` |
| Root/SSH manifest           | `overlays/local_manifests/` | Placeholder; MVP uses adbd-TCP instead |
| TWRP recovery manifest      | `overlays/local_manifests/` | Deferred |
| Permissive SELinux          | already the upstream default | No action needed |
| Skip setup wizard, stay on when plugged | Via `overlays/init/*.rc` | Same mechanism, not yet ported |
| UART settings               | `docs/uart-config.md` + `apply-customizations.sh` | **Uses the CORRECT per-board device nodes**; does not override raspberry-vanilla defaults |
| adb root / root access      | `apply-customizations.sh` | Sets `persist.adb.tcp.port=5555` |

**What we dropped on purpose:**

- The 52 KB `aaos.sh` monolith — split into small numbered scripts.
- Per-distro `setup_build_env.sh` — replaced by Lima VM provisioning.
- Pi 5-only hardcoding — the new project supports both boards via a
  `pi4|pi5` argument to `03-build.sh` and `04-extract-image.sh`.
- Wrong `UART_DEVICE="ttyAMA0"` default — we now trust the
  raspberry-vanilla cmdline.
- Interactive prompts in the orchestrator — everything is scriptable
  and unattended so it can run under Claude Code / CI.

## Recommendation

Use `/Volumes/stuff/rpi/aaos` going forward. Keep the `RPi_AAOS16`
tree as read-only reference if you want to mine its `settings.conf`
knobs or the TWRP manifest later. Do **not** try to build from it
with the current upstream — the `_r3` pin and `bp2a` lunch suffix
will fail.
