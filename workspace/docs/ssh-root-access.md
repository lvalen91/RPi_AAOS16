# Root Shell Over Ethernet — Design & Usage

**Goal:** reach a root shell on a running Pi (4 or 5) over the RJ45
ethernet interface, for troubleshooting. No serial cable needed.

## Approach — MVP: adbd over TCP

We're building `userdebug` AAOS images, which already support `adb
root`. The simplest way to get "root SSH on ethernet" is to expose
the existing Android Debug Bridge daemon over TCP and connect from
any host on the same LAN.

`apply-customizations.sh` injects these properties into
`device/brcm/rpi{4,5}/system.prop`:

```
persist.adb.tcp.port=5555
service.adb.tcp.port=5555
persist.sys.ethernet.enable=1
ro.tether.denied=false
```

After the build boots on the Pi:

```bash
# on any macOS/Linux box on the same LAN
adb connect 192.168.1.42:5555         # replace with the Pi's IP
adb root                              # drops into root mode
adb shell                             # full root shell
adb push / pull                       # file transfer
adb logcat                            # streaming logs
```

**Finding the Pi's IP:** check your router's DHCP lease table, or
boot once with a monitor and read it from the status bar / Settings
→ About.

### Why not real SSH?

Running OpenSSH on Android is possible but painful: you'd need
either `dropbear` built as an AOSP project with an `init.rc` service,
or sideloaded as an APK. For troubleshooting `adb` over TCP is
strictly better:

- Native tooling (`adb logcat`, `adb bugreport`, `adb push/pull`).
- Already supported by AOSP userdebug — no extra projects.
- `adb shell` gives you a root shell on userdebug.
- Works over any IP transport (ethernet, WiFi hotspot, USB tether).

## Approach — Full SSH via dropbear (follow-up)

If the Pi must be reachable by strangers (fleet deployment, CI
bastions, etc.) who don't have `adb` installed, we'd add a real SSH
server. Sketch:

1. Create a custom `local_manifest.xml` under `overlays/local_manifests/`
   referencing an external dropbear fork ported to AOSP bp (e.g.
   `external/dropbear`).
2. Add `PRODUCT_PACKAGES += dropbear dropbearconvert ssh scp` in a
   `device/brcm/rpi*/device.mk` fragment under `overlays/`.
3. Ship an `init.dropbear.rc` under `overlays/init/`:

   ```
   service dropbear /system/bin/dropbear -R -s -p 22
       class main
       user root
       group root
       oneshot
       disabled

   on property:sys.boot_completed=1
       start dropbear
   ```

4. Drop `overlays/ssh/authorized_keys` — `apply-customizations.sh`
   already stages it under `device/brcm/rpi*/root/root_ssh/`, which
   we'd then copy into `/data/.ssh/authorized_keys` via an init
   action.
5. SELinux is already permissive in raspberry-vanilla, so no new
   policy is needed for the MVP. For production you'd write a
   proper policy for `dropbear`.

This is deferred: the `adb-over-TCP` path covers everything needed
for troubleshooting today.

## Ethernet at boot

AAOS on raspberry-vanilla already starts `EthernetService` with DHCP
on `eth0` at boot when an interface is present. You don't need to
touch `init.rc` for that. The only thing we add is
`persist.sys.ethernet.enable=1` (redundant on most builds, harmless
safety net).

Verify on the running Pi:

```bash
adb shell ip addr show eth0
adb shell dumpsys ethernet
```

If `eth0` is down:

```bash
adb shell svc ethernet enable
```

## Connecting the first time (no IP known yet)

Two options:

1. **Serial console** (see `docs/uart-config.md`). Boot the Pi, read
   the DHCP lease from `dmesg` or:
   ```
   adb shell ip addr show eth0     # once adb over USB works
   ```
2. **USB-OTG adb**: plug a USB-C cable from the Pi into a
   host machine. `dtoverlay=dwc2,dr_mode=peripheral` is already set
   in the raspberry-vanilla `config.txt`. `adb devices` will show
   the Pi. From there:
   ```
   adb shell ip addr show eth0
   adb tcpip 5555
   adb connect <pi-ip>:5555
   ```

## Security posture

- `userdebug` + `SELinux permissive` + adbd-on-TCP is **explicitly
  insecure**. Do not put this on a hostile network unfiltered.
- Put the Pi behind a LAN or add `iptables` rules on your router to
  block :5555 from WAN.
- For a production build, switch to `user` build type, disable
  `adbd`, and run dropbear with key-only auth.
