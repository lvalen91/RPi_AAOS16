# Sources

Every external URL this workspace leans on, grouped by purpose.
Captured 2026-04-09. Links that were current at capture time are
marked; the raspberry-vanilla GitHub URLs track HEAD and can drift.

## Canonical build paths

- **noahchalifour/aaos-rpi** — top-level wrapper, all 6 lunch targets.
  <https://github.com/noahchalifour/aaos-rpi>
- **raspberry-vanilla/android_local_manifest** (branch `android-16.0`)
  — the manifest we add to `.repo/local_manifests/`.
  <https://github.com/raspberry-vanilla/android_local_manifest/tree/android-16.0>
- **raspberry-vanilla/android_kernel_manifest** (branch `android-16.0`)
  — kernel build tree (`common-android16-6.12-lts`); only needed if
  you rebuild the kernel yourself (we don't).
  <https://github.com/raspberry-vanilla/android_kernel_manifest/tree/android-16.0>

## Device trees (authoritative for UART / partitions / SELinux)

- Pi 4: <https://github.com/raspberry-vanilla/android_device_brcm_rpi4/tree/android-16.0>
- Pi 5: <https://github.com/raspberry-vanilla/android_device_brcm_rpi5/tree/android-16.0>
- Shared vendor blobs:
  <https://github.com/raspberry-vanilla/proprietary_vendor_brcm>

## Google AOSP

- `repo` tool: <https://storage.googleapis.com/git-repo-downloads/repo>
- AOSP requirements:
  <https://source.android.com/docs/setup/start/requirements>
- AOSP build-numbers / tag-to-branch mapping:
  <https://source.android.com/docs/setup/reference/build-numbers>
- Android 16 release notice (biannual Q2/Q4 cadence announcement):
  <https://groups.google.com/g/android-building/c/c4_W34xH55I>

## Community builds & hardware notes

- KonstaKANG's AOSP 16 for Pi 5 (build Dec 4 2025):
  <https://konstakang.com/devices/rpi5/AOSP16/>
- XDA — AOSP (Android 16) for Pi 4 & Pi 5:
  <https://xdaforums.com/t/dev-rom-aosp-android-16-for-raspberry-pi-4-pi-5.4744648/>
- Raspberry Pi Forums — AOSP (Android 16) for Pi 4 & Pi 5, CM4/CM5:
  <https://forums.raspberrypi.com/viewtopic.php?t=389025>
- Exton RaspAnd 16 Build 260314 (Mar 14 2026, kernel 6.12.67):
  <https://extonlinux.wordpress.com/2026/03/14/raspand-16-android-16-for-raspberry-pi-5-with-gapps-google-play-store-spotify-and-bluetooth-pre-installed-build-260314/>
- Emteria — Android 16 on Raspberry Pi and CM5 support:
  <https://emteria.com/blog/android-16-on-raspberry-pi-and-major-updates>

## Automotive-specific walkthroughs

- Narendra Harny — **Build AOSP Android 16 Automotive OS for Raspberry
  Pi 5 and flash it** (Make Android, Medium). Written against
  `_r1`/`bp2a`; still useful for the AAOS service wiring commentary.
  <https://medium.com/make-android/build-aosp-android-16-automotive-os-for-raspberry-pi-5-and-flash-it-cc24efd24410>
- Grape Up — **AAOS 13 on Raspberry Pi 4B** (detailed automotive
  service writeup: VHAL mock, audiocontrol@2.0, automotive display
  framework, EVS mock, automotive launcher overlay). Older AOSP, but
  the best explanation of what "automotive" actually adds.
  <https://grapeup.com/blog/android-automotive-os-13-on-raspberry-pi-4b>
- Grape Up — earlier AAOS on Pi 4B:
  <https://grapeup.com/blog/android-automotive-os-on-raspberry-pi-4b>
- Snapp Automotive — AAOS 13 on Pi 4:
  <https://www.snappautomotive.io/blog/android-automotive-os-13-on-a-raspberry-pi-4>
- AOSP & AAOS Meetup — Pi 4 device docs:
  <https://aospandaaos.github.io/device-rpi4.html>

## UART references (critical — Pi 4 ≠ Pi 5)

- Raspberry Pi Forums — **Pi 5 dedicated UART header (3-pin JST)**:
  <https://forums.raspberrypi.com/viewtopic.php?t=363667>
- Raspberry Pi Forums — **Configuring Pi 5 UARTs** (solved):
  <https://forums.raspberrypi.com/viewtopic.php?t=359132>
- Raspberry Pi Forums — **Pi 5 UART configuration, `dtparam=uart0_console`,
  EEPROM 2025-02-12 behaviour**:
  <https://forums.raspberrypi.com/viewtopic.php?t=395082>
- Raspberry Pi Forums — **ttyAMA10 stability on RPi 5**:
  <https://forums.raspberrypi.com/viewtopic.php?t=396509>
- Raspberry Pi Forums — **debug UART for CM5 on CM5 IO devkit**:
  <https://forums.raspberrypi.com/viewtopic.php?t=382356>
- GitHub issue — **Update UART documentation for Pi5**:
  <https://github.com/raspberrypi/documentation/issues/3239>
- Ubuntu bug — **Pi 5 serial console device changes with kernel**:
  <https://bugs.launchpad.net/bugs/2101104>
- Raspberry Pi config reference (`enable_uart`, `disable-bt`, etc.):
  <https://www.raspberrypi.com/documentation/computers/configuration.html#configure-uarts>
- Jeff Geerling — Attaching to Pi serial console (Pi 4-era reference):
  <https://www.jeffgeerling.com/blog/2021/attaching-raspberry-pis-serial-console-uart-debugging/>
- Emteria — USB-to-TTL wiring for Pi UART:
  <https://emteria.com/kb/connect-uart-rpi>

## Tooling

- Lima: <https://lima-vm.io>  / <https://github.com/lima-vm/lima>
- Ubuntu 22.04 cloud image (amd64):
  <https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img>
- Raspberry Pi Imager: <https://www.raspberrypi.com/software/>

## Prior art in this session

- The user's existing framework (superseded by this workspace; kept
  as read-only reference):
  `/Users/zeno/Downloads/GitHub/RPi_AAOS16` — see
  `docs/rpi-aaos16-framework-analysis.md`.
