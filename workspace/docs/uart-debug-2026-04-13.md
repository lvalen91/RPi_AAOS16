# UART debug — 2026-04-13 — Pi 4 mini-UART garbled on ttyS0

> ## ⚠ SUPERSEDED 2026-08-16 — DO NOT APPLY THE FIX BELOW
>
> The recommended fix in this document (`dtoverlay=miniuart-bt`) was reasoned out but never
> verified on hardware. When the image was finally run on a Pi 4 it **broke both Bluetooth and
> the serial console**. See [`os-corrections-2026-08-16.md`](os-corrections-2026-08-16.md) §1.
>
> **The specific error** is in the "Fix" section below, which states that swapping BT onto the
> mini-UART is *"harmless for the console path"* because *"our console is `ttyS0` on GPIO
> 14/15"*. It is not. `miniuart-bt` **swaps which controller is wired to GPIO 14/15**: after the
> overlay the header carries **PL011 (`ttyAMA0`)** and `ttyS0` belongs to Bluetooth. So
> `console=ttyS0` then points at the Bluetooth UART rather than at the pins — the header goes
> silent — while `hci_uart_bcm` binds to the PL011 now on the header and talks HCI out the GPIO
> pins instead of to the CYW43455 (`hci0: hardware error 0x10`, BT stack crash-looping).
>
> Confirmed from the live device tree: the overlay adds a `bluetooth` node to `uart1` **without
> removing** the base DTB's node on `uart0`, so both UARTs claimed one.
>
> **Verified working configuration:** no overlay + `console=ttyS0,115200` — console *and*
> Bluetooth both healthy. The `not valid maps for state default` symptom this document
> diagnoses did **not** reproduce on the 2026-04-13 build with that configuration.
>
> If that symptom ever does return, the coherent version of this document's idea is
> `dtoverlay=miniuart-bt` **together with `console=ttyAMA0,115200`** — note the cmdline change
> is not optional, and it costs BT the better UART. The "third option" warning about
> `dtoverlay=uart0` below remains correct.
>
> Everything above the "Fix" heading — the pinctrl and VPU-clock analysis, and the source
> references — is still useful background and is not disputed here.

## Symptoms (recap)

- `enable_uart=1` in `/boot/config.txt` ✓
- `console=ttyS0,115200` in `/boot/cmdline.txt` ✓
- Kernel log at +1.65 s:
  ```
  bcm2835-aux-uart fe215040.serial: there is not valid maps for state default
  printk: legacy console [ttyS0] disabled
  ```
- Firmware-stage chars appear on GPIO 14/15 but kernel/Android output is
  garbled at 115200.
- PL011 enumerated as `ttyAMA1` (not `ttyAMA0`) — a tell-tale of device
  re-numbering caused by a missing/partially-applied pinmux.

## Root cause

Two compounding issues.

### 1. Mini-UART pinctrl default state is missing

The android-common kernel (`common-android16-6.12-lts`) is Google's
branch of mainline 6.12 — **not** the Raspberry Pi Foundation's `rpi-6.12.y`
tree. Kernel source tree: `kernel/common` under android.googlesource.com
[1]. It contains the upstream `pinctrl-bcm2835.c` driver [2] and the
upstream `bcm2711-rpi-4-b.dts` device tree.

In the upstream `bcm2711.dtsi`, `uart1` (the aux-UART / mini-UART at
`fe215040`) is declared with `status = "disabled"` by default, and the
pinctrl mapping that puts TXD1/RXD1 on GPIO 14/15 lives in an overlay,
NOT in the base DTB. On stock Pi OS, `enable_uart=1` causes the
*closed-source VideoCore firmware* to apply a runtime DT fixup that
(a) flips `uart1` to `okay` and (b) adds the `pinctrl-0 = <&uart1_gpio14>`
reference.

When the aliases table in the android-common DT differs from the stock
Pi OS tree (it does — raspberry-vanilla ships a snapshot that has
evolved independently), the firmware fixup matches imperfectly:
`uart1` gets enabled (so the driver probes, hence the `fe215040.serial`
kernel message) but the `pinctrl-names = "default"` entry is not
populated with a phandle — producing exactly the observed error:

> `bcm2835-aux-uart fe215040.serial: there is not valid maps for state default`

The console then gets disabled because pinmux failed, matching the
next line in dmesg.

The PL011 coming up as `ttyAMA1` rather than `ttyAMA0` confirms the
aliases table disagrees between firmware fixup and the on-disk DTB.

### 2. Mini-UART baud is VPU-clock-derived

Even if pinctrl succeeded, the mini-UART's baud clock is derived from
the VPU core clock [3][4]. `arm_boost=1` (present in
raspberry-vanilla's `boot/config.txt`) lets the VPU clock scale under
load, causing the 115200 baud rate to drift enough to garble output.

## Fix

Add one line to `boot/config.txt`:

```
dtoverlay=miniuart-bt
```

What this does, from the Raspberry Pi firmware overlays README [5]:

- Explicitly defines the aux-uart (`uart1`) pinmux for GPIO 14/15 — no
  longer relying on the firmware DT fixup matching the android-common
  DT aliases. The `pinctrl-0 = <&uart1_gpio14>` phandle gets baked into
  the overlayed DT, so the `state default` mapping resolves.
- Swaps Bluetooth off UART0 (PL011) onto UART1 (mini-UART). Since our
  console is `ttyS0` on GPIO 14/15 and BT is routed internally on the
  SoC, this is harmless for the console path. BT-over-mini-UART costs
  BT a little bandwidth but we are not using BT for telephony.
- Implicitly pins `core_freq` so the mini-UART baud stays at 115200.

An alternative — `dtoverlay=disable-bt` plus changing
`BOARD_KERNEL_CMDLINE` to `console=ttyAMA0,115200` — would move the
console onto the full PL011 and turn off BT entirely. Cleaner for a
dev console, but it changes the kernel cmdline (requires a rebuild of
the boot image, not just a config.txt edit) and kills BT. **Not
recommended for this project** — we want the minimal diff.

A third option — `dtoverlay=uart0` — would also route PL011 to
GPIO 14/15, but doesn't handle the BT swap, so BT would fight for the
same pins. **Do not use.**

## Recommended one-line fix

File: `device/brcm/rpi4/boot/config.txt` (in the AOSP tree) — AKA the
source we copy via `apply-customizations.sh`.

Line to add (right below `enable_uart=1`):

```
dtoverlay=miniuart-bt
```

Encoding this idempotently in `scripts/vm/apply-customizations.sh` is
the next step (tracked separately). After the next rebuild + reflash,
expect:

- `ls /dev/tty{S0,AMA0}` shows both present
- `dmesg | grep -i 'fe215040.serial'` shows `ttyS0 at MMIO ...` with
  no "not valid maps" line
- Clean 115200 8N1 output on GPIO 14/15 throughout boot and after
  Android init

## Sources

1. Android common kernel manifest, android-16.0 branch:
   <https://android.googlesource.com/kernel/manifest/+/refs/heads/common-android16-6.12-lts>
2. pinctrl-bcm2835 in kernel/common:
   <https://android.googlesource.com/kernel/common/+/refs/heads/common-android16-6.12-lts/drivers/pinctrl/bcm/pinctrl-bcm2835.c>
3. Raspberry Pi UART documentation, mini-UART VPU-clock dependency:
   <https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-uarts>
4. Raspberry Pi issue #4849 — garbled mini-UART at higher kernel versions:
   <https://github.com/raspberrypi/linux/issues/4849>
5. Firmware `overlays/README` (miniuart-bt, disable-bt, uart0):
   <https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README>
6. Issue #5182 — "not valid maps for state default" root-cause discussion:
   <https://github.com/raspberrypi/linux/issues/5182>
7. raspberry-vanilla kernel overlays (confirms `miniuart-bt.dtbo` ships in the Android build):
   <https://github.com/raspberry-vanilla/android_device_brcm_rpi4-kernel/tree/android-16.0/overlays>
8. raspberry-vanilla `boot/config.txt` (confirms no `dtoverlay=miniuart-bt` present upstream):
   <https://github.com/raspberry-vanilla/android_device_brcm_rpi4/blob/android-16.0/boot/config.txt>
