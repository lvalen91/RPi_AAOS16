# AAOS on Raspberry Pi — Project Guide for Claude

## Project purpose

Workspace for building Android Automotive OS (AOSP Android 16) for
Raspberry Pi 4 and Pi 5. Scripts, docs, overlays and built images live
under `/Volumes/stuff/rpi/aaos`. The Lima **instance** lives in the
shared lima home (see below).

## Current state (as of 2026-08-14)

### Pi 4 build: DONE — and now HARDWARE-TESTED (2026-08-16)

- **Image:** `out/RaspberryVanillaAOSP16-20260413-rpi4_car.img` (15.4 GB)
- In-VM artifacts: `~/aosp/out/target/product/rpi4/{boot,system,vendor,ramdisk}.img`
- **Status:** flashed and booted on a Pi 4 (4 GB). Boots, adb over USB-C + RJ45, audio, BT and
  a 5 GHz AP all now working — **but only after 8 corrections**, three of them critical.
- **Lunch:** `aosp_rpi4_car-bp4a-userdebug`

> ### ⚠ BEFORE REBUILDING ANY IMAGE, READ [`docs/os-corrections-2026-08-16.md`](docs/os-corrections-2026-08-16.md)
>
> It lists every change the shipped image needed, verified on hardware. The three that matter
> most:
> 1. **Remove `dtoverlay=miniuart-bt` from `boot/config.txt`** — it kills Bluetooth *and* the
>    serial console. This **supersedes `docs/uart-debug-2026-04-13.md`**, which recommends
>    adding it; that doc now carries a correction banner.
> 2. **`ro.boot.wificountrycode` must be a real ISO code, not `00`** — world domain makes every
>    5 GHz channel no-IR.
> 3. **The Wi-Fi vendor HAL's `IWifiApIface.setCountryCode` must not return `NOT_SUPPORTED`** —
>    `SoftApManager` requires a country code for 5 GHz (but not 2.4 GHz), so this single gap
>    blocks all 5 GHz SoftAP. Upstream's "5 GHz hotspot" support appears never to have worked.
>
> The doc also records a **boot-breaking trap**: never route HDMI audio by editing
> `audio_policy_configuration.xml` / `car_audio_configuration.xml` — use the
> `persist.vendor.audio.device` property. The XML route causes a SIGABRT crash loop with
> `sys.boot_completed` never set.

### Pi 5 build: NOT YET STARTED

- User wants Pi 4 confirmed working on hardware first, then Pi 5
- ccache is warm but only modestly (see "ccache reality check" below)

### Lima VM: STOPPED between sessions (state preserved)

- Instance `aaos-builder`, **302 GB** on disk
- **`LIMA_HOME=/Volumes/stuff/virtual-machines/lima`** — set by `scripts/env.sh`
- AOSP tree: `~/aosp` inside the VM (294 GB incl. `out/`), fully synced
- To resume: `./scripts/01-create-vm.sh` (~30 s)
- All `limactl` use requires `source scripts/env.sh` first (or use the
  numbered scripts, which do it automatically)

## Host environment

| | |
|---|---|
| Machine  | Mac Pro 2019 (MacPro7,1), Intel Xeon W-3265 — **24 physical / 48 logical**, 240 GiB RAM |
| macOS    | 26.6.1 (25G76) |
| Lima     | 2.2.0 (Homebrew), QEMU 11.1.0 |
| Storage  | External APFS volume `/Volumes/stuff` — PCIe/NVMe SSD, ~1.4 TiB free |

## VM configuration

Live config: `$LIMA_HOME/aaos-builder/lima.yaml`.
Template for fresh VMs: `templates/aaos-builder.yaml`.

| | |
|---|---|
| Driver   | `qemu` + HVF (`-machine q35,accel=hvf`) |
| Guest    | Ubuntu 22.04.5 LTS, kernel 5.15 |
| vCPUs    | **48** (raised from 24 on 2026-08-14) |
| Memory   | **200 GiB** (raised from 192 GiB) |
| Disk     | 600 GiB sparse — guest sees 582 GB ext4, ~285 GB free |
| cpuType  | `host,-avx512vl,-pdpe1gb,+invtsc` |
| Networking | default user-mode (slirp). socket_vmnet block is **disabled** |

### Why QEMU and not vz — corrected 2026-08-14

Older docs in this repo claim "vz / Virtualization.framework is Apple
Silicon only." **That is wrong** and was measured to be wrong on this
host. `vz` does boot an x86_64 Linux guest on this Intel Mac.

The real blocker: VZ builds a **36-bit guest physical address space**, so
guest RAM is capped at 64 GiB — and any larger request **silently falls
back to ~3 GiB** with no warning or error. Measured: 16/32/48/60/63 GiB
all work; 64, 96, 128 and 200 GiB all yield 3 GiB. `limactl list` still
cheerfully reports "200GiB".

QEMU with `accel=hvf` has no such cap and reaches the full 200 GiB across
48 vCPUs at genuine hardware-virtualisation speed (measured 47.7x parallel
scaling). So the conclusion "use qemu" was right; the stated reason was not.

Corollary: **QEMU+HVF is not emulation.** Docs saying builds pay "~20-30%
emulation overhead" are wrong; HVF is hardware virtualisation. Real overhead
is virtio I/O and the mandatory AVX-512 mask, not CPU emulation.

### AVX-512 mask is MANDATORY

`-avx512vl` must stay in `cpuType`. Removing it was tried on 2026-04-13 and
the guest **kernel-panicked at boot** (`invalid opcode at
raid6_avx5124_gen_syndrome`): HVF on this host advertises AVX-512 in CPUID
but fails to execute EVEX-prefixed instructions. `docs/build-tuning-2026-04-13.md`
recommends dropping the mask — **do not follow that recommendation.**

### Why 48 vCPUs is safe

Soong caps its memory-hungry `highmem` pool (linkers) via
`build/soong/ui/build/config.go`:

```go
const minMemPerHighmemProcess = 8 * 1024 * 1024 * 1024
} else if p := int(c.totalRAM / minMemPerHighmemProcess); p < parallel {
```

At 196 GiB usable that is `196/8 = 24` highmem jobs — **the same 24 it was
at the old 24-vCPU setting.** Raising vCPUs to 48 therefore does not raise
peak link memory at all; it only widens the cheap compile pool. The extra
threads buy roughly +3-5% compile throughput (per the 2026-04-13 research)
at the cost of macOS responsiveness during a build.

**If the Mac becomes unusable while building, drop `cpus` back to 24.**
Only ~40 GiB is left for macOS at 200 GiB, and QEMU's RSS grows as the
guest page cache fills, so the host gets tight late in a long build.

## ccache reality check

`CLAUDE.md` previously claimed "ccache (200 GB) is warm." **It is not.**
Measured 2026-08-14:

| | |
|---|---|
| Location | `~/aosp/out/.ccache` (**not** `~/.ccache`, which is empty) |
| Size     | 8.3 GB of a 200 GB cap |
| Hit rate | 23.06% (16280 / 70594) |

Only the 2026-04-13 Pi 4 build populated it; the 2026-04-10 build ran with
`USE_CCACHE` unset. Expect a Pi 5 build to benefit, but not dramatically —
budget closer to the cold-build end of the range.

### CCACHE_DIR must stay under `$OUT_DIR`

This looks like the anti-pattern Google warns about (cache sharing a disk
with `out/`), and `docs/build-tuning-2026-04-13.md` recommends moving it to
a dedicated disk. **Do not move it to `$HOME` or a host mount.** AOSP 16's
Soong wraps every Ninja action in an nsjail sandbox that bind-mounts `/`
read-only and only grants RW to `/tmp`, the source tree and `out/`. A
`CCACHE_DIR` in `$HOME` makes the build die with "Read-only file system"
(see `build/soong/ui/build/sandbox_linux.go`).

If you want to separate cache I/O from `out/` I/O, the only safe shape is an
`additionalDisks:` entry **mounted at `~/aosp/out/.ccache`** so it stays
inside nsjail's RW bind. Verify nsjail follows the submount before relying
on it — this has not been tested.

Trade-off already accepted: `make clean`/`clobber` wipes `out/` and therefore
the cache. Our workflow never does that.

## Upstream pins

| | |
|---|---|
| AOSP tag          | `android-16.0.0_r4` (Android 16 QPR2) |
| Manifest          | `raspberry-vanilla/android_local_manifest` @ `android-16.0` |
| Lunch suffix      | **`bp4a`** (was `bp2a` under `_r1` — older guides are wrong) |
| Kernel            | `common-android16-6.12-lts` (precompiled, no kernel build step) |
| Mesa / libcamera  | 25.3.1 / 0.6.0 |
| Google cadence    | Biannual Q2/Q4 AOSP releases starting 2026 |

## Build customizations applied (via `scripts/vm/apply-customizations.sh`)

Applied idempotently before each build to `device/brcm/rpi{4,5}/`:

- `system.prop`: `persist.adb.tcp.port=5555`, `service.adb.tcp.port=5555`, `persist.sys.ethernet.enable=1`
- `BoardConfig.mk`: `BOARD_KERNEL_CMDLINE += cpufreq.default_governor=performance`
- `device.mk`: `PRODUCT_PACKAGES += DocumentsUI` (ships as `CarDocumentsUI` in the automotive build)

## Build environment exports (in `scripts/vm/build-aaos.sh`)

Set explicitly in the script, **not** inherited from `~/.bashrc` — Ubuntu's
`.bashrc` returns early on non-interactive shells, which is exactly how
`vm_run` invokes the build. The original Pi 4 build silently ran with
`USE_CCACHE` unset because of this.

```sh
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export CCACHE_DIR="$AOSP_DIR/out/.ccache"
export CCACHE_COMPRESS=1
export SOONG_RUSTC_INCREMENTAL=true   # unpins rustc from -C codegen-units=1
```

## UART — boards differ (critical)

- **Pi 4:** `console=ttyS0,115200` — mini UART on GPIO 14 (TX) / GPIO 15 (RX). `enable_uart=1` in config.txt.
- **Pi 5:** `console=ttyAMA10,115200` — dedicated 3-pin JST SH debug header near power button. NOT GPIO 14/15.
- Raspberry-vanilla defaults are correct. `apply-customizations.sh` verifies without overriding.
- See `docs/uart-config.md` for full wiring details.

## Guest performance tunables (applied 2026-08-14)

See `docs/host-performance-2026-08-14.md` for the measurements behind these.

| Setting | Value | Where |
|---|---|---|
| `vm.dirty_bytes` | 4 GiB | `/etc/sysctl.d/99-aosp-perf.conf` |
| `vm.dirty_background_bytes` | 1 GiB | same |
| `read_ahead_kb` | 512 | `/etc/udev/rules.d/60-virtio-readahead.rules` |
| `nofile` soft+hard | 1048576 | `/etc/security/limits.conf` |

The dirty-page change is the important one: the kernel defaults are *ratios*
(20% / 10%), which on a 196 GiB guest meant buffering **~39 GiB** of dirty
pages before hard-throttling — a ~41 s stall at the measured 958 MB/s write
throughput. Absolute byte limits cap that at a few seconds.

## Build performance (observed)

| Phase | Duration | Notes |
|---|---|---|
| VM creation + provisioning | ~2 min | One-time; preserved across restarts |
| `repo sync` (first, ~168 GB) | ~45 min | `-j32`, partial clone with blob:limit=10M |
| Pi 4 first build | **~10.5 hours** | ccache was inactive (see above); 20 vCPUs at the time |
| Pi 5 build (projected) | ~6-9 hours | ccache only 23% warm; 48 vCPUs now |
| `mkimg.sh` | ~2 min | Creates the ~15 GB flashable .img |
| Image extract (VM → host) | ~20 s | Via 9p mount to /mnt/out |

Storage ceiling, measured inside the guest: **3.6 GB/s read, 958 MB/s write**
(2 GiB `dd`, `oflag=direct`).

## Architecture decisions and known gotchas

### SSH ControlPersist masks guest config changes

Lima's generated `ssh.config` sets `ControlMaster auto` / `ControlPersist yes`.
A `limactl shell` reuses the existing master, so changes to PAM limits or
anything else session-scoped **will not appear** in new shells. Force a
reconnect:

```bash
ssh -F "$LIMA_HOME/aaos-builder/ssh.config" -O exit lima-aaos-builder
```

### socket_vmnet is gone

`/opt/socket_vmnet/bin/socket_vmnet` is no longer installed on this host, so
the `networks: [{lima: shared}]` block made the VM fail to start. It is now
commented out in `lima.yaml`; the VM uses default user-mode networking. Per
the 2026-04-13 research there is no proven throughput benefit for this
workload (repo sync was upstream-bound either way). To restore: run
`scripts/setup-vmnet.sh`, then uncomment.

### 9p cache coherency (FIXED)

Lima's 9p mount (`/mnt/scripts`) caches aggressively. Host edits to
`scripts/vm/*.sh` may not be visible inside the VM. **Fix:** host wrappers
use `vm_push_scripts` (tar-over-stdin) to copy scripts to `/tmp/aaos-scripts/`
in the guest before execution. `/mnt/scripts` is historical; scripts execute
from the local copy.

### Naming: pi4 vs rpi4

User-facing arg is `pi4`/`pi5` (short). All internal paths, lunch targets, and
device trees use `rpi4`/`rpi5`. Scripts accept both and canonicalize via:
```bash
case "$TARGET" in pi4|rpi4) BOARD=rpi4 ;; pi5|rpi5) BOARD=rpi5 ;; esac
```

### AOSP + `set -u`

AOSP's `build/envsetup.sh` references unset variables (`$TOP`, `$OUT_DIR`).
Do NOT use `set -u` in any script that sources `envsetup.sh`. `build-aaos.sh`
uses `set -eo pipefail` (no `-u`).

### `set -e` inside process substitutions

`ls` inside `<(...)` with `set -e` active: if the first `ls` glob misses, the
subshell exits before the second `ls` runs. Always append `|| true` to
fallible commands inside process substitutions.

### Image size

`mkimg.sh` hardcodes `IMGSIZE=15360000000` (15.36 GB). Userdata is ~11.7 GB
regardless of SD card size. Auto-resize on first boot is a deferred TODO
(see `docs/todo.md`).

## Workflow for subsequent builds

```bash
cd /Volumes/stuff/rpi/aaos
./scripts/01-create-vm.sh             # restart existing VM (~30 s)
# If upstream changed:
./scripts/02-sync-aosp.sh             # incremental sync (minutes, not hours)
# Build:
./scripts/03-build.sh pi4             # or pi5   (self-wraps in caffeinate)
./scripts/04-extract-image.sh pi4     # → out/RaspberryVanillaAOSP16-<date>-rpi4_car.img
# Stop when done:
./scripts/vm-stop.sh
```

## Key files

| File | Purpose |
|---|---|
| `scripts/env.sh` | Sourced by all scripts; sets `LIMA_HOME`, `vm_push_scripts`, `vm_run`, `start_log` |
| `scripts/vm/apply-customizations.sh` | Idempotent device-tree mods (UART, adbd-TCP, governor, DocumentsUI) |
| `scripts/vm/build-aaos.sh` | ccache/rustc env + lunch + make + mkimg.sh |
| `templates/aaos-builder.yaml` | Lima VM definition (for fresh VMs) |
| `$LIMA_HOME/aaos-builder/lima.yaml` | Live instance config (edited directly for existing VM) |
| `reference/raspberry-vanilla/` | Upstream file snapshots for diffing |
| `docs/host-performance-2026-08-14.md` | vz cap, HVF findings, storage + writeback tuning |
| `docs/build-tuning-2026-04-13.md` | Earlier research — **read its correction banner first** |
| `docs/todo.md` | Deferred work (userdata auto-resize, dropbear SSH, settings.conf knobs) |
| `docs/uart-config.md` | Critical Pi 4 vs Pi 5 UART differences |

## What NOT to do

- Do NOT run `limactl` without `LIMA_HOME` set — it will look in `~/.lima` and
  miss this VM. Use the numbered scripts or `source scripts/env.sh` first.
- Do NOT remove `-avx512vl` from `cpuType` — guest kernel panic at boot.
- Do NOT move `CCACHE_DIR` out of `$OUT_DIR` — nsjail makes it read-only.
- Do NOT use `set -u` in scripts that source AOSP's `build/envsetup.sh`.
- Do NOT edit scripts in `scripts/vm/` and expect the VM to pick up changes
  immediately — the 9p cache is unreliable. The numbered scripts handle this
  via `vm_push_scripts`.
- Do NOT default to conservative parallelism (j12, 50 GB ccache) — this is a
  24c/48t Mac Pro with 240 GiB RAM. Use workstation defaults.
- Do NOT assume Pi 4 and Pi 5 UART are the same (Pi 4 = ttyS0/GPIO,
  Pi 5 = ttyAMA10/JST-SH header).
- Do NOT `pkill -9 qemu-system-x86_64` — HVF can leak vCPU threads and require
  a host reboot. Use `./scripts/vm-stop.sh`.
