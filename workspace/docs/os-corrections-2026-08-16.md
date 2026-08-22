# OS corrections required before building an rpi4 AAOS image — 2026-08-16

**Read this before compiling.** Every item below was found by running the
`RaspberryVanillaAOSP16-20260413-rpi4_car.img` build on real Pi 4 hardware and is
**empirically verified on-device** unless explicitly marked otherwise. Several items broke
functionality outright; two of them broke it silently.

Hardware under test: Pi 4 Model B, 4 GB. Build fingerprint
`Raspberry/aosp_rpi4_car/rpi4:16/BP4A.251205.006/eng.zeno`, API 36, arm64,
`androidboot.selinux=permissive`, no dm-verity.

Confidence key: **[V]** verified on hardware · **[S]** established from AOSP/kernel source ·
**[U]** unverified recommendation.

---

## Summary

| # | Correction | Where | Severity |
|---|---|---|---|
| 1 | Remove `dtoverlay=miniuart-bt` | `boot/config.txt` | **Critical** — kills Bluetooth *and* the serial console |
| 2 | `ro.boot.wificountrycode` must be a real ISO code, not `00` | `vendor.prop` | **Critical** for 5 GHz |
| 3 | `IWifiApIface.setCountryCode` must not return `NOT_SUPPORTED` | Wi-Fi vendor HAL | **Critical** — blocks 5 GHz SoftAP entirely |
| 4 | Set the kernel regulatory domain at boot | init `.rc` | **Critical** — brcmfmac never learns the country otherwise |
| 5 | Filter `NO_IR` channels out of the SoftAP channel list | framework / HAL | High — random un-beaconable channel picks |
| 6 | Default `persist.vendor.audio.device` | `vendor.prop` | Medium — audio silently goes to the 3.5 mm jack |
| 7 | Persist adb root | `build.prop` | Low — convenience |
| 8 | eth0 gets no address | init `.rc` | Low — no DHCP on a direct link |
| 11 | **`CONFIG_BT_RFCOMM=y`** | kernel config | **Critical** — without it iAP2-over-Bluetooth cannot run at all |

---

## 1. `dtoverlay=miniuart-bt` must be REMOVED  [V]

**This corrects `docs/uart-debug-2026-04-13.md`, which recommends adding it.** That
recommendation is wrong and was never hardware-verified (CLAUDE.md recorded the image as
"awaiting user hardware test").

### What actually happens

`miniuart-bt` does not merely add a pinmux for the mini-UART. It **swaps which controller is
wired to GPIO 14/15**: after the overlay, the header carries **PL011 (`ttyAMA0`)** and the
mini-UART (`ttyS0`) is handed to Bluetooth. The prior doc assumed the console stayed on
`ttyS0` at the header and called the BT swap "harmless for the console path" — that is the
load-bearing error.

With `console=ttyS0,115200` still in `cmdline.txt`, the result on hardware is:

- The kernel console is emitted onto the UART **Bluetooth now owns** → the GPIO header is
  silent, so the serial console appears dead.
- `hci_uart_bcm` binds to `serial0-0` = the PL011 that is now routed to the header, i.e. the
  kernel talks HCI **out the GPIO pins**, to whatever USB-serial cable is attached, instead of
  to the CYW43455.

Observed symptoms:

```
Bluetooth: hci0: Received unexpected HCI Event 0x00
Bluetooth: hci0: Frame reassembly failed (-84)      # EILSEQ, x22
Bluetooth: hci0: command 0xfc18 tx timeout          # BCM UPDATE_BAUDRATE
Bluetooth: hci0: BCM: Reset failed (-110)
Bluetooth: hci0: hardware error 0x10
init: Untracked process (name: (droid.bluetooth) ... state: Z) exited
```

Confirmed from the live device tree — **both** UARTs carried a `bluetooth` child node, because
the overlay adds one to `uart1` without removing the base DTB's node on `uart0`:

```
serial0 -> /soc/serial@7e201000   (PL011)      status=okay  bluetooth child: YES
serial1 -> /soc/serial@7e215040   (mini-UART)  status=okay  bluetooth child: YES
```

### The fix

Delete the line from `device/brcm/rpi4/boot/config.txt` (upstream raspberry-vanilla does **not**
ship it — this was a local addition). Keep `enable_uart=1` and `console=ttyS0,115200`.

Verified result: serial console returns on GPIO 14/15 at 115200, **and** Bluetooth initialises
cleanly with zero reassembly failures:

```
Bluetooth: hci0: BCM4345C0 'brcm/BCM4345C0.hcd' Patch
Bluetooth: hci0: BCM43455 37.4MHz Raspberry Pi 3+-0190
Bluetooth: hci0: BCM4345C0 (003.001.025) build 0382     # 0000 -> 0382 = patchram loaded
```

### The three possible configurations

Only two are coherent. Do not mix them.

| Config | `config.txt` | `cmdline.txt` | GPIO 14/15 | Bluetooth | Verdict |
|---|---|---|---|---|---|
| **A (use this)** | no overlay | `console=ttyS0` | mini-UART | PL011 | **[V]** Both work; BT gets the better UART |
| **B (fallback)** | `miniuart-bt` | `console=ttyAMA0` | PL011 | mini-UART | **[U]** Coherent; BT degraded (mini-UART has no HW flow control, VPU-clock-derived) |
| **Broken** | `miniuart-bt` | `console=ttyS0` | PL011 | mini-UART | **[V]** Console dead, BT dead — the shipped state |

Use **B** only if the original `bcm2835-aux-uart ... there is not valid maps for state default`
problem from the 2026-04-13 doc reappears. It did **not** reproduce on this build with
config A — the mini-UART console was clean throughout boot and after Android init. Do not
diagnose a UART issue by adding the overlay without also moving `console=`.

> **Do NOT "fix" this by keeping the overlay and changing `console=` because of a `/dev/ttyS0`
> string in the vendor partition.** That string is not the BT attachment. `hci_uart_bcm` is a
> **serdev** driver bound through the device tree; the BT HAL reaches `hci0` via the kernel and
> never opens a tty node. (I made this mistake mid-investigation; the device tree settled it.)

---

## 2. `ro.boot.wificountrycode=00` blocks all 5 GHz  [V]

Upstream ships world domain in `vendor.prop`:

```
ro.boot.wificountrycode=00      # -> change to US (or your real deployment ISO code)
```

Under regdomain `00` every 5 GHz channel is no-IR, so no 5 GHz AP can beacon. Note that
upstream's entire *"wifi: enable 5GHz hotspot"* commit
([`13af585`](https://github.com/raspberry-vanilla/android_device_brcm_rpi4/commit/13af585d0df8110de3c5653a21ffd2422f31c4bf))
consists of adding `wificountrycode=00` plus `config_wifi_softap_ieee80211ac_supported=true` —
which cannot have worked, and indeed **no user report of a working 5 GHz hotspot on any
RaspberryVanilla/KonstaKANG build exists** across GitHub, XDA, the Pi forums or Reddit. Treat
upstream's "wifi tethering works" claim as covering 2.4 GHz only.

Fixing this prop alone is **not sufficient** — see items 3 and 4.

---

## 3. The real 5 GHz SoftAP blocker: `IWifiApIface.setCountryCode`  [V]

### Symptom

`cmd wifi start-softap X wpa2 P -b 2` works (2437 MHz). `-b 5` fails; hostapd starts and exits
cleanly in ~0.69 s having never been given an AP config.

### Root cause (captured live)

```
E WifiApIfaceAidlImpl: setCountryCode failed with service-specific exception: (code 4)
E SoftApManager[wlan0]: Failed to set country code, required for setting up soft ap in band: 2
```

`band: 2` = `SoftApConfiguration.BAND_5GHZ`; code 4 = `WifiStatusCode.ERROR_NOT_SUPPORTED`.
`SoftApManager.setCountryCode()` treats a country code as **mandatory for 5 GHz and optional for
2.4 GHz** — which is exactly the observed asymmetry. The request dies at
`START_RESULT_FAILURE_SET_COUNTRY_CODE` before `IHostapd.addAccessPoint()` is ever called.

Corroborating evidence: the generated `/data/vendor/wifi/hostapd/hostapd_wlan0.conf` was
**not rewritten** during a band-5 attempt (identical mtime and content to the previous band-2
run), and hostapd never logs its `AddSingleAccessPoint, iface=wlan0` entry line.

### Why the driver never has a country code  [S]

Two independent reasons, both need to be understood before patching:

1. **brcmfmac registers a static custom regdomain with `alpha2 = "99"`** that is never updated
   after a country change (`brcm80211/brcmfmac/cfg80211.c:224`, applied via
   `wiphy_apply_custom_regulatory`). It exists to strip `NO_IR` from 5 GHz 36–48/149–165. So
   `wificond` can only ever report `Current driver country code 99`, which is not a parseable
   ISO code → `mDriverCountryCode: null`. **This is by-design driver behaviour, not a fault.**
2. **`config_wifiDriverSupportedNl80211RegChangedEvent` defaults to `false`**, so genuine
   nl80211 regulatory events are discarded by the framework anyway.

### The fix  [U]

Make the vendor Wi-Fi HAL's `IWifiApIface.setCountryCode` **succeed** instead of returning
`NOT_SUPPORTED`. Because item 4 already sets the kernel regulatory domain independently, the
HAL does not need to do real work — the regulatory state it would be "setting" is already
correct. Returning success is sufficient to let `SoftApManager` proceed.

Alternative (touches the mainline Wi-Fi module, less preferable): patch `SoftApManager` to not
require a country code for band 5.

### Hypotheses eliminated — do not re-investigate these

- **Not the CLM blob.** It loads: the `brcmf_c_process_clm_blob: no clm_blob available` line is
  *absent* from dmesg. (The `no txcap_blob available (err=-2)` warning **is** present and is
  cosmetic — every working Raspberry Pi shows it. Likewise the
  `brcmfmac43455-sdio.raspberrypi,4-model-b.bin failed with error -2` fallback is by design.)
- **Not the firmware or the chip.** Zero `brcmfmac`/`phy0` errors in dmesg during any failed
  attempt. Proven affirmatively — see item 9.
- **Not 11ax/11be.** Eliminated twice: the framework ANDs them away
  (`config_wifiSoftapIeee80211axSupported`/`...beSupported` both default false), *and* the rpi
  hostapd APEX is compiled without `CONFIG_IEEE80211AX`/`CONFIG_IEEE80211BE`.
- **Not DFS/no-IR on the target channels.** `iw phy` shows 36–48 enabled at 20 dBm with no
  no-IR flag, and `AP` present in supported interface modes.
- **Not the device overlays.** `config_wifi5ghzSupport=true` and
  `config_wifiSoftap5ghzSupported=true` (AOSP default) are both effective on-device.

---

## 4. Set the kernel regulatory domain at boot  [V]

Because of the `alpha2 = "99"` behaviour above, the framework prop never reaches the kernel
regdomain. Without an explicit `iw reg set`, `iw phy` exposes **no** 5 GHz band at all.

After `iw reg set US` the phy correctly exposes:

```
Band 2: 5170 [34], 5180 [36], 5190 [38], 5200 [40] ... @ 20 dBm
Supported interface modes: ... AP ...
```

Add to a boot-time init service (see item 8 for the `.rc` gotcha):

```sh
/system/bin/iw reg set US
```

---

## 5. Filter `NO_IR` from the SoftAP channel list  [S]

Once a country code is established, `SoftApCapability` populates as:

```
SupportedChannelListIn5g[34, 36, 38, 40, 42, 44, 46, 48, 149, 153, 157, 161, 165]
```

That is **not a valid US AP set** — 34/38/42/46 are Japan-legacy 5170–5230 spacing. It is a raw
phy dump with no `NO_IR` filtering. `ApConfigUtil.chooseApChannel()` picks **randomly** from
this list, so most picks are un-beaconable and the AP fails intermittently. Filter the list, or
constrain it via `config_wifiSoftap5gChannelList`.

Note `-f <freq>` bypasses this path entirely — an explicit channel is never validated against
the capability list — which is how item 3 was isolated from item 5.

**Stay on channels 36–48.** Firmware 7.45.265 (the version shipped) has a documented CLM
regression affecting 149–165: [raspberrypi/linux#7186](https://github.com/raspberrypi/linux/issues/7186).

---

## 6. Audio silently defaults to the 3.5 mm jack  [V]

The rpi audio HAL (`/apex/com.android.hardware.audio.rpi/...`, ALSA-backed via `libasound` +
`libalsautilsv2-rpi.so`) selects its output from a single property:

```
persist.vendor.audio.device = jack | hdmi0
```

Default is `jack`. `hdmi0` = ALSA card 1 = `vc4hdmi0` = connector **HDMI-A-1** (the Pi's HDMI0
port, nearest USB-C). Set the default in `vendor.prop` if HDMI audio is wanted out of the box.

> ### Boot-breaking trap — do NOT do it via the audio XMLs
>
> Adding an `AUDIO_DEVICE_OUT_HDMI` devicePort to
> `/vendor/etc/audio_policy_configuration.xml` and repointing
> `/vendor/etc/car_audio_configuration.xml` at it puts the device into a **SIGABRT crash loop
> every ~5 s with `sys.boot_completed` never set.** Two reasons:
> 1. In `carAudioConfiguration version="3"`, `<device address="…">` is matched against a
>    devicePort's **`address` attribute — never its `tagName`**. A devicePort without an
>    `address` matches nothing and CarAudioService aborts.
> 2. With dynamic routing disabled (this device's state), `car_audio_configuration.xml` is
>    **not parsed at all**, so the edit is pointless as well as fatal.
>
> `/vendor/lib64/hw/audio.primary.default.so` is the AOSP **stub** HAL ("Default audio HW HAL",
> no ALSA linkage) and is vestigial — do not reason from it.

---

## 7. adb root does not persist  [V]

`adb remount` refuses with "Device must be bootloader unlocked", but there is **no dm-verity**
(`ro.boot.veritymode` and `ro.boot.verifiedbootstate` are both empty), so
`mount -o remount,rw /` and `/vendor` work directly.

To keep adbd root across reboots on userdebug, append to `/system/build.prop`:

```
service.adb.root=1
```

`persist.adb.tcp.port=5555` already ships enabled, so adb-over-TCP works as soon as an
interface has an address. There is **no sshd on the image** and nothing cheap to add one.

---

## 8. eth0 never gets an address — and the init `.rc` gotcha  [V]

Android's `EthernetManager` does not claim `eth0` on this build, and a direct cable to a host
has no DHCP server, so the interface comes up with no IPv4 and inbound traffic is dropped
(IPv6 link-local does not answer either).

A oneshot init service fixes it, but **`seclabel` is mandatory**:

```
# /vendor/etc/init/carlink_eth0.rc
service carlink_boot /system/bin/sh /vendor/bin/carlink_boot.sh
    user root
    group root root net_admin net_raw
    capabilities NET_ADMIN NET_RAW
    seclabel u:r:su:s0
    oneshot
    disabled

on property:sys.boot_completed=1
    start carlink_boot
```

Without `seclabel`, init refuses to start it:

```
Could not ctl.start for 'carlink_boot': File /system/bin/sh (labeled "u:object_r:shell_exec:s0")
has incorrect label or no domain transition from u:r:init:s0 to another SELinux domain defined.
```

**That check fires even under permissive SELinux** — the error message says so explicitly. This
is the single easiest way to lose an hour.

Script body (combines items 4 and 8):

```sh
#!/system/bin/sh
/system/bin/ip link set eth0 up
/system/bin/ip addr add 1.1.1.2/16 dev eth0 2>/dev/null
/system/bin/iw reg set US
exit 0
```

---

## 9. Proven-good: 5 GHz AP via standalone hostapd  [V]

This is both the interim workaround **and** the proof that the hardware is innocent. With
framework Wi-Fi disabled (`svc wifi disable`, which releases `wlan0`):

```
# /data/local/tmp/hostapd_5g.conf
interface=wlan0
driver=nl80211
ctrl_interface=/data/vendor/wifi/hostapd/ctrl_carlink
ssid=pi-carplay
country_code=US
ieee80211d=1
hw_mode=a
channel=36
ieee80211n=1
ieee80211ac=1
vht_oper_chwidth=0
wmm_enabled=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=<passphrase>
```

```sh
/apex/com.android.hardware.wifi.hostapd.rpi/bin/hw/hostapd -dd /data/local/tmp/hostapd_5g.conf
/system/bin/dnsmasq --no-daemon --no-resolv --port=0 --interface=wlan0 --bind-interfaces \
  --dhcp-authoritative --dhcp-range=192.168.43.100,192.168.43.200,12h
```

Result:

```
hostapd: wlan0: interface state COUNTRY_UPDATE->ENABLED
hostapd: wlan0: AP-ENABLED
iw dev:  ssid pi-carplay, type AP, channel 36 (5180 MHz), txpower 31.00 dBm
```

Two gotchas: hostapd's Android build logs to **logcat (tag `hostapd`), not stdout** — a
stdout redirect captures an empty file; and `ctrl_interface` must point somewhere writable
(`/data/local/tmp` fails with `mkdir[ctrl_interface]: Permission denied`).

Caveat: this lives outside Android's Wi-Fi framework, so tethering, ConnectivityService and the
Settings UI know nothing about it, and it needs its own init wrapper to survive reboot.

---

## 10. Not fixable in the image  [V]

The Pi 4 has **no RTC battery**, and with no reachable NTP the clock resets to the build date
every boot. `persist.sys.timezone` *does* persist. Re-sync from a host with:

```sh
adb shell "date -u $(date -u +%m%d%H%M%Y.%S)"
```

Also note: display modes come only from the connected sink's EDID. A `video=` line in
`cmdline.txt` for a *disconnected* connector is a silent no-op, and `video=` does not add modes
that SurfaceFlinger can see regardless — it enumerates the connector's probed mode list. Check
which connector is live with `cat /sys/class/drm/card0-HDMI-A-*/status` before assuming.

---

## 11. `CONFIG_BT_RFCOMM` is not enabled — blocks iAP2 over Bluetooth  [V]

Found 2026-08-16 while bringing up the CarPlay accessory stack natively on the Pi.

```
$ zcat /proc/config.gz | grep -i rfcomm
# CONFIG_BT_RFCOMM is not set

$ awk '{print $1}' /proc/net/protocols | grep -iE 'l2cap|rfcomm|hci|sco'
SCO
L2CAP
HCI
```

`socket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM)` therefore fails with **`EPROTONOSUPPORT`
(os error 93)**. Everything else in the accessory identity works on this kernel — the controller
comes up, Class of Device / local name / raw EIR are all settable, SSP negotiates Just-Works, and
an L2CAP SDP server binds PSM 0x0001 and serves the `Wireless iAPv2` record. Only the RFCOMM
transport underneath iAP2 is missing.

This is not an oversight in the device tree: **Android's own Bluetooth stack implements RFCOMM in
userspace** over L2CAP, so AOSP has no reason to enable the kernel module. It only matters if
something drives the controller directly, which is exactly what a native CarPlay accessory does.

### The fix

One line in the kernel config, then rebuild the kernel:

```
CONFIG_BT_RFCOMM=y
```

(`=m` is not useful here — this build ships no loadable modules and `lsmod` is empty.)

Kernel repo: `raspberry-vanilla/android_kernel_brcm_rpi`, branch `android-16.0`. Note the Wi-Fi
firmware and `regulatory.db` are compiled in via `CONFIG_EXTRA_FIRMWARE`, so a kernel rebuild is
also the opportunity to pick up a newer CLM blob (item 5).

### If a kernel rebuild is not available

The alternative is to implement RFCOMM (TS 07.10) in userspace over an L2CAP socket on PSM 3 —
the multiplexer session (SABM/UA on DLCI 0), parameter negotiation, per-DLC open, UIH framing and
credit-based flow control. That is precisely what Android's own stack does, so it is a proven
approach rather than a novel one, but it is several hundred lines of protocol code and carries far
more risk than the one-line config change. Prefer the kernel fix whenever a build host exists.

---

## Post-flash verification checklist

```sh
adb shell 'getprop sys.boot_completed'                       # 1
adb shell 'ls /sys/class/bluetooth/; dmesg | grep -c "Frame reassembly failed"'   # hci0, 0
adb shell 'dmesg | grep "BCM4345C0.*Patch"'                  # patchram loaded
adb shell 'getprop ro.boot.wificountrycode'                  # US, not 00
adb shell 'iw phy | grep -c "5[0-9][0-9][0-9].0 MHz"'        # non-zero
adb shell 'id'                                               # uid=0 without `adb root`
adb shell 'ip addr show eth0 | grep "inet "'                 # has an address
adb shell 'getprop persist.vendor.audio.device'              # jack | hdmi0
adb shell 'cmd wifi start-softap T wpa2 Passw0rd123 -b 5'    # the real test
# UART: 115200 8N1 on GPIO 14/15 should give a console prompt
```

A re-runnable diagnostic that captures the full SoftAP failure (generated hostapd.conf, A/B
band 2 vs 5, dmesg deltas, nl80211 events) and restores device state afterwards lives at
`tools/diag_softap_5g.sh` (also mirrored from the sibling carlink project).
