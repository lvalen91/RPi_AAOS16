# Platform patches

AOSP-project patches for the Raspberry Pi 4 automotive build, one directory per
repo project. Every one is a fix for something **measured on hardware**, not a
preference — see `../workspace/docs/os-corrections-2026-08-16.md` for the
evidence behind each.

```
patches/
├── apply.sh                    apply everything below to a synced AOSP tree
├── build_kernel_rpi4.sh        out-of-tree kernel build + install
├── device_brcm_rpi4/           board config, audio, sepolicy
├── hardware_interfaces/        Wi-Fi AIDL HAL
├── external_ffmpeg_codec2/     HEVC decoder output path
└── kernel_brcm_rpi/            kernel defconfig (applied by build_kernel_rpi4.sh)
```

## Usage

```sh
./patches/apply.sh ~/aosp                 # in-tree projects
./patches/build_kernel_rpi4.sh ~/aosp     # kernel (separate: rpi4-kernel is a prebuilt)
```

`apply.sh` is idempotent — an already-applied patch is detected and skipped.

## What each one does

**`device_brcm_rpi4`** — the board corrections. `dtoverlay=miniuart-bt` off (it
breaks Bluetooth *and* the serial console, because the overlay leaves a
bluetooth node on both UARTs and `hci_uart_bcm` binds the PL011 that was just
routed to the GPIO header). `ro.boot.wificountrycode` set to a real ISO code
(`00` marks every 5 GHz channel no-IR). `persist.vendor.audio.device=hdmi0`
(that one property is the whole output switch — editing the audio policy XML
instead gives a SIGABRT boot loop). USB audio pinned to 16-bit with a tunable
period count. `/dev/media0` labelled `media_device`.

**`hardware_interfaces`** — `IWifiApIface.setCountryCode` falls back to
`NL80211_CMD_REQ_SET_REG` when the vendor HAL cannot do it.

`BOARD_WLAN_DEVICE=bcmdhd` makes `libwifi-hal` link Broadcom's vendor HAL, whose
`wifi_set_country_code()` drives BRCM-OUI nl80211 vendor subcommands belonging
to the out-of-tree DHD driver. A Pi runs upstream `brcmfmac`, which implements
none of them, so the call returns `NOT_SUPPORTED`. That single gap blocks **all
5 GHz SoftAP**, because `SoftApManager` requires a country code before bringing
up a 5 GHz AP (it does not for 2.4 GHz). As far as we can tell upstream's
"5 GHz hotspot" support has never worked on this platform for exactly this
reason.

**`external_ffmpeg_codec2`** — the HEVC output path made two full-frame CPU
passes where one would do: the hwaccel transfer detiled SAND into a scratch
AVFrame, then `sws_scale` copied yuv420p to yuv420p at identical dimensions into
the C2 graphic block — source and destination format and size all equal, so
swscale took its unscaled copy path and the "conversion" was a memcpy. Measured
at ~33% of one Cortex-A72 core for a near-static 1080p stream. The patch
resolves the hardware frame lazily, once the C2 block is mapped, and transfers
straight into it. Falls back to the old path on any failure and for HEVC Main 10,
so it cannot regress a stream that decodes today.

**`kernel_brcm_rpi`** — `CONFIG_BT_RFCOMM=y`. Without it
`socket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM)` returns `EPROTONOSUPPORT`.

Built in rather than `=m` on purpose: this defconfig ships no modules (see
upstream `aa8bafbbf816`, "rpi4: defconfig: don't build modules") and
`device/brcm/rpi4-kernel` carries only `Image` and dtbs, so a module would never
be loadable. Upstream has since set `=m` at HEAD, which on this board is
equivalent to leaving it off.

## Status

Applied and built against `android-16.0.0_r4` + raspberry-vanilla `android-16.0`,
2026-08-22, and **verified on a Pi 4 Rev 1.5** the same day.

| Item | Result on hardware |
|---|---|
| `CONFIG_BT_RFCOMM=y` | `zcat /proc/config.gz` → `CONFIG_BT_RFCOMM=y` |
| `miniuart-bt` removed | BT enables, `BCM4345C0` patchram loads, **zero** `Frame reassembly failed` / `tx timeout` / `hardware error` |
| Wi-Fi country code | `ro.boot.wificountrycode=US`; kernel regdomain `country US: DFS-FCC` after wpa_supplicant starts — no manual `iw reg set` |
| `setCountryCode` fallback | **Load-bearing.** Log: `setCountryCode: vendor HAL returned -3; falling back to nl80211 NL80211_CMD_REQ_SET_REG`. `-3` is `WIFI_ERROR_NOT_SUPPORTED`, exactly as predicted |
| 5 GHz SoftAP | **Works via the framework.** `SAP is enabled successfully`, `AP-ENABLED`, 80 MHz on ch149/157, and an external Mac sees the SSID beaconing. Previously hostapd exited in 0.69 s |
| `mDriverCountryCode` | `US` (was `null`); framework enumerates 5 GHz AP channels `[34…165]` |
| `/dev/media0` label | `u:object_r:media_device:s0` |
| Audio / USB props | `persist.vendor.audio.device=hdmi0`, `ro.audio.usb.period_us=10000`, `ro.audio.usb.period_count=8` |
| `service.adb.root=1` | root shell without `adb root` |

Still unproven, because they need a running CarPlay session or hardware that was
not attached:

- the HEVC decoder fast path (`external_ffmpeg_codec2`) — needs a session; the
  fallback means a failure degrades to the old two-pass path rather than breaking
- USB audio period retune — needs a USB audio device attached
- RFCOMM is enabled in the kernel but iAP2-over-Bluetooth has not been run against it

Car audio remains in legacy mode by design — see the note in the top-level README.
