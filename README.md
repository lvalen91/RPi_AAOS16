# RPi_AAOS16

Android Automotive OS (AOSP Android 16) on the Raspberry Pi, built from source.

There is very little public material on getting AAOS running properly on a Pi,
and almost none of it survives contact with real hardware. This repo is the
**platform** half of that work: board bring-up, image configuration, and the
fixes that turned out to be necessary once a board was actually booted, wired to
a display, and driven.

Application work built *on top* of this platform lives in its own repos. Nothing
here depends on them.

## What's here

```
├── aaos.sh, scripts/, settings.conf   Pi 5 build flow — config-driven, runs on a Linux host
├── local_manifests/                   repo manifests (root/SSH, TWRP)
├── overlay/                           resource overlays applied to the source tree
├── patches/                           Pi 4 platform patches + kernel build   ← see patches/README.md
└── workspace/                         macOS + Lima build workspace, docs, research
```

Two build paths, because they grew separately:

- **Pi 5** — `aaos.sh` / `scripts/`, driven by `settings.conf`. Builds directly
  on a Linux host. Includes TWRP and root/SSH options.
- **Pi 4** — `workspace/scripts/` (numbered, `00-` … `04-`), which drives a Lima
  VM from a macOS host, plus `patches/`. This is the path that has been taken all
  the way to a booting, hardware-tested image.

They are not yet unified. If you only care about one board, use its path.

## Pi 4: the short version

```sh
./workspace/scripts/01-create-vm.sh          # Lima VM (macOS host)
./workspace/scripts/02-sync-aosp.sh          # repo init + sync (~100-150 GB)
./patches/apply.sh ~/aosp                    # platform patches
./patches/build_kernel_rpi4.sh ~/aosp        # kernel — rpi4-kernel is a prebuilt, so this is separate
./workspace/scripts/03-build.sh pi4
./workspace/scripts/04-extract-image.sh pi4
```

## Read this before rebuilding anything

`workspace/docs/os-corrections-2026-08-16.md` — every correction the shipped
image needed, verified on a Pi 4 Rev 1.5. The three that matter most:

1. **Remove `dtoverlay=miniuart-bt`.** It kills Bluetooth *and* the serial
   console. This supersedes `workspace/docs/uart-debug-2026-04-13.md`, which
   recommends adding it; that doc now carries a correction banner. The trap is
   easy to reintroduce — the build's own customization script was re-adding it
   on every build until 2026-08-22.
2. **`ro.boot.wificountrycode` must be a real ISO code, not `00`.** The world
   domain marks every 5 GHz channel no-IR.
3. **The Wi-Fi vendor HAL's `IWifiApIface.setCountryCode` must not return
   `NOT_SUPPORTED`.** `SoftApManager` requires a country code for 5 GHz (but not
   for 2.4 GHz), so this one gap blocks all 5 GHz SoftAP. See
   `patches/hardware_interfaces/`.

And one boot-breaking trap: **never route HDMI audio by editing
`audio_policy_configuration.xml` / `car_audio_configuration.xml`** — use the
`persist.vendor.audio.device` property. The XML route causes a SIGABRT crash
loop in which `sys.boot_completed` is never set.

## Known limitations

- **Car audio runs in legacy mode.** `car_audio_configuration.xml` is not parsed
  at all: no audio zones, no volume groups, no dynamic routing. Enabling
  `audioUseDynamicRouting` is not a config flip — AAOS bus routing needs one
  `AUDIO_DEVICE_OUT_BUS` port per volume group, and the Pi audio HAL's
  `StreamAlsa` opens one tinyalsa proxy per stream with no mixer, so N bus ports
  would mean N concurrent `pcm_open` on a single ALSA device. It needs a HAL that
  can mix, not an XML edit.
- **The Pi 4 has no microphone.** Any capture needs a USB device, and a
  full-speed one cannot carry 24-bit 48 kHz stereo at the default ring size —
  see the USB audio notes in `patches/README.md`.
- The Pi 5 path has not been through the same hardware verification as the Pi 4
  path.

## Upstream

Built on [raspberry-vanilla](https://github.com/raspberry-vanilla) —
`android_local_manifest`, `android_device_brcm_rpi{4,5}`,
`android_kernel_brcm_rpi`. Several patches here are candidates to send upstream.
