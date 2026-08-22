# UART / Serial Console — Pi 4 vs Pi 5

Pi 4 and Pi 5 have **different UART layouts**. Anything that tells you
"connect a USB-TTL adapter to GPIO 14/15 at 115200, that's the Android
console on both boards" is wrong for the Pi 5.

## Raspberry-vanilla defaults (verified 2026-04-09)

From `device/brcm/rpi{4,5}/BoardConfig.mk` on branch `android-16.0`:

| | Pi 4 | Pi 5 |
|---|---|---|
| `BOARD_KERNEL_CMDLINE` | `console=ttyS0,115200 …` | `console=ttyAMA10,115200 …` |
| Physical connection | GPIO 14 (TX) / GPIO 15 (RX) | dedicated 3-pin JST SH debug header |
| Linux device node | `/dev/ttyS0` (mini UART) | `/dev/ttyAMA10` (PL011 on RP1) |
| Baud | 115200 8N1 | 115200 8N1 |
| Default `enable_uart=1` in config.txt? | yes | no (the dedicated header is routed regardless) |
| `androidboot.hardware` | `rpi4` | `rpi5` |

**The defaults are already correct.** Our `apply-customizations.sh`
does not change `BOARD_KERNEL_CMDLINE`; it only ensures Pi 4 keeps
`enable_uart=1` in `boot/config.txt` (which it does already).

## Pi 4 hookup

```
USB-TTL         Raspberry Pi 4 GPIO header (40-pin)
──────          ─────────────────────────────────────
GND  ────────── Pin 6  (GND)
RX   ────────── Pin 8  (GPIO 14, TXD, UART0)
TX   ────────── Pin 10 (GPIO 15, RXD, UART0)
```

Host side:

```bash
screen /dev/tty.usbserial-XXXX 115200
# or
picocom -b 115200 /dev/tty.usbserial-XXXX
```

**Important:** Pi 4 raspberry-vanilla uses `console=ttyS0` — the **mini
UART**, not PL011. Bluetooth stays on PL011 (`ttyAMA0`). You do **not**
need `dtoverlay=disable-bt`. Mini UART clock tracks the VPU clock so
baud rate can drift under heavy load but is reliable enough for console.

If you prefer PL011 on GPIO 14/15 (and are willing to sacrifice BT),
add to `boot/config.txt`:

```
dtoverlay=disable-bt
```

and change `BOARD_KERNEL_CMDLINE` to `console=ttyAMA0,115200`.

## Pi 5 hookup

Pi 5 has a **dedicated debug UART header** — a 3-pin JST SH (1.0 mm
pitch) socket labelled `UART` near the power button. This is a brand
new board feature; there is no equivalent on Pi 4.

```
Pi 5 JST SH UART connector  (looking at the silkscreen label)
  pin 1 ── RX   (Pi receives)
  pin 2 ── GND
  pin 3 ── TX   (Pi transmits)
```

You need a 3-pin JST SH to USB-TTL cable (Raspberry Pi sell an
official one; many third-party variants exist).

- **GPIO 14/15 is NOT the console on Pi 5 by default.** `ttyAMA10` on
  the dedicated header is.
- The Pi 5 bootloader supports exactly one UART: the 3-pin header.
- Starting with EEPROM 2025-02-12, adding `enable_uart=1` to
  `config.txt` **moves** the console from the debug header to
  GPIO 14/15. Don't do that unless you have a specific reason.
- If you want the console on GPIO 14/15 anyway (e.g. sharing a HAT
  with a UART passthrough), add `dtparam=uart0_console` to
  `boot/config.txt` and change `BOARD_KERNEL_CMDLINE` to
  `console=ttyAMA0,115200`.

## CM4 / CM5 notes

CM4 inherits the Pi 4 UART topology. CM5 inherits the Pi 5 topology
**but the dedicated JST SH header is on the CM5 IO board, not the
module itself**. Check the CM5 IO board silkscreen — there have been
revision-specific silkscreen errors in 2025.

## Verifying on a running Pi

Once Android has booted:

```bash
adb shell getprop ro.hardware        # should be rpi4 or rpi5
adb shell cat /proc/cmdline          # should include console=ttyS0 (pi4) or console=ttyAMA10 (pi5)
adb shell dmesg | grep -i serial
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Nothing on GPIO 14/15 on Pi 5 | Correct — console is on the JST SH header |
| Garbled output on Pi 4 ttyS0 | Mini UART clock drift; try lower baud (57600) or switch to ttyAMA0 |
| `ttyAMA10` missing on Pi 5 Android | Check `cat /proc/cmdline`; raspberry-vanilla default is `console=ttyAMA10,115200` |
| Boot proceeds but no Android logs | `no_console_suspend` is set in cmdline; if absent, add it |
| Console cuts off after kernel hands off to init | Expected — Android init redirects to `/dev/kmsg`; use `adb logcat` instead once the network is up |

## Sources

- `device/brcm/rpi4/BoardConfig.mk` and `boot/config.txt` at
  <https://github.com/raspberry-vanilla/android_device_brcm_rpi4/tree/android-16.0>
- `device/brcm/rpi5/BoardConfig.mk` at
  <https://github.com/raspberry-vanilla/android_device_brcm_rpi5/tree/android-16.0>
- Pi 5 dedicated UART header: <https://forums.raspberrypi.com/viewtopic.php?t=363667>
- Pi 5 UART configuration: <https://forums.raspberrypi.com/viewtopic.php?t=359132>
- Pi 5 `dtparam=uart0_console`, EEPROM 2025-02-12 behaviour: <https://forums.raspberrypi.com/viewtopic.php?t=395082>
- CM5 IO debug UART: <https://forums.raspberrypi.com/viewtopic.php?t=382356>
