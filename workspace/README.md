# AAOS on Raspberry Pi — Build Workspace

Self-contained workspace for building **Android Automotive OS** (AOSP
Android 16) for **Raspberry Pi 4 and Raspberry Pi 5** on a macOS host
via a Lima VM.

Scripts, docs, overlays and built images live under this directory.

The Lima **instance** lives in the shared lima home at
`/Volumes/stuff/virtual-machines/lima` (moved there 2026-08-14 from
`./lima`, so this VM sits alongside the machine's other Lima instances).
`scripts/env.sh` sets `LIMA_HOME` accordingly — nothing lands in `~/.lima`.

```
aaos/
├── README.md                  ← you are here
├── docs/                      ← all research and design docs
│   ├── research-2026-04-09.md            upstream pins, component versions
│   ├── rpi-aaos16-framework-analysis.md  user's older framework, what we kept/dropped
│   ├── uart-config.md                    Pi 4 (ttyS0) vs Pi 5 (ttyAMA10) serial
│   ├── ssh-root-access.md                root over RJ45 via adbd-TCP
│   ├── lima-setup.md                     VM management
│   ├── build-commands.md                 canonical AOSP commands
│   ├── sources.md                        bibliography
│   └── session-log-2026-04-09.md         session chronology / handoff
├── reference/                 ← upstream file snapshots (read-only)
│   └── raspberry-vanilla/
│       ├── manifest_brcm_rpi.xml
│       ├── remove_projects.xml
│       ├── README-local_manifest.md
│       ├── README-kernel_manifest.md
│       ├── rpi4/{BoardConfig.mk, boot-config.txt, device.mk}
│       └── rpi5/{BoardConfig.mk, boot-config.txt, device.mk}
├── templates/
│   └── aaos-builder.yaml      ← Lima VM definition
├── scripts/                   ← host-side orchestration
│   ├── env.sh                 ← sourced by every host script
│   ├── 00-check-host.sh       ← verify macOS host is ready
│   ├── 01-create-vm.sh        ← create + start the Lima VM
│   ├── 02-sync-aosp.sh        ← repo init + sync inside VM
│   ├── 03-build.sh pi4|pi5    ← build AAOS for one board
│   ├── 04-extract-image.sh .. ← copy built .img back to host
│   ├── vm-shell.sh            ← drop into the VM
│   ├── vm-status.sh vm-stop.sh vm-destroy.sh
│   ├── logs-tail.sh           ← tail -F latest log (for monitoring)
│   ├── logs-list.sh           ← list all logs w/ status
│   └── vm/                    ← runs INSIDE the VM (mounted r/o at /mnt/scripts)
│       ├── sync-aosp.sh
│       ├── build-aaos.sh
│       ├── extract-image.sh
│       └── apply-customizations.sh
├── overlays/                  ← custom manifests, init.rc, SSH keys (optional)
│   ├── local_manifests/
│   ├── init/
│   └── ssh/
├── logs/                      ← host-side per-run logs (tee'd in real-time)
└── out/                       ← built flashable .img files land here
```

## Monitoring a running build

Every numbered script tees its output to `logs/<tag>-<timestamp>.log`
while still printing to your terminal. From a second terminal:

```bash
./scripts/logs-tail.sh              # follow the newest log of any tag
./scripts/logs-tail.sh sync-aosp    # or a specific tag
./scripts/logs-list.sh              # all logs, with status (done/running/failed)
```

See [docs/logging.md](docs/logging.md) for details including how to
filter noisy `make` output, where Lima's own logs live, and how to
leave a build running with `nohup`.

## Host

- **Mac Pro 2019** (MacPro7,1, Xeon W-3265), 24 physical / 48 logical cores, 240 GiB RAM
- macOS 26.6.1, Lima 2.2.0 + QEMU 11.1.0 (Homebrew)
- Project lives on external APFS volume `/Volumes/stuff` — PCIe/NVMe SSD, ~1.4 TiB free
- Lima uses the **QEMU** driver with `accel=hvf` — real hardware virtualisation,
  not emulation. `vz` is *not* Apple-Silicon-only as older notes claimed; it
  works here but caps guest RAM at 64 GiB and silently falls back to ~3 GiB
  above that, which is why QEMU is used. See
  [docs/host-performance-2026-08-14.md](docs/host-performance-2026-08-14.md).

## Quickstart

```bash
cd /Volumes/stuff/rpi/aaos

# First time only:
./scripts/00-check-host.sh            # verify RAM / cores / disk / lima
./scripts/01-create-vm.sh             # create & provision the Lima VM (Ubuntu 22.04)
./scripts/02-sync-aosp.sh             # repo init android-16.0.0_r4 + sync   (~168 GB, ~45 min)

# Build (Pi 4 already done; Pi 5 pending user confirmation):
./scripts/03-build.sh pi4             # build Pi 4 automotive               (~10.5 h cold)
./scripts/03-build.sh pi5             # build Pi 5 automotive               (benefits from Pi 4 ccache)
./scripts/04-extract-image.sh pi4     # copy .img from VM → ./out/
./scripts/04-extract-image.sh pi5

# When done:
./scripts/vm-stop.sh                  # stop VM (state preserved in qcow2)
```

Flash `./out/RaspberryVanillaAOSP16-<date>-rpi{4,5}_car.img` with
Raspberry Pi Imager or Balena Etcher. Minimum 16 GB SD card (32 GB
recommended).

## Current state (2026-08-14)

| | |
|---|---|
| **Pi 4 image**  | `out/RaspberryVanillaAOSP16-20260413-rpi4_car.img` (15.4 GB) -- built, awaiting hardware test |
| **Pi 5 image**  | not yet built -- waiting for Pi 4 confirmation first |
| **Lima VM**     | stopped, state preserved (302 GB on disk). `./scripts/01-create-vm.sh` to resume (~30 s) |
| **VM resources**| 48 vCPU / 200 GiB / 600 GiB disk (raised from 24 / 192 GiB on 2026-08-14) |
| **ccache**      | `~/aosp/out/.ccache` — 8.3 GB, 23% hit rate. Warm, but not as warm as older notes claimed |

## Key facts

| | |
|---|---|
| **AOSP branch** | `android-16.0.0_r4` (Android 16 QPR2) |
| **Manifest**    | `raspberry-vanilla/android_local_manifest` @ `android-16.0` |
| **Lunch**       | `aosp_rpi4_car-bp4a-userdebug` / `aosp_rpi5_car-bp4a-userdebug` |
| **Kernel**      | `common-android16-6.12-lts` (precompiled, no kernel build step) |
| **UART Pi 4**   | `console=ttyS0,115200` on GPIO 14/15 (mini UART) |
| **UART Pi 5**   | `console=ttyAMA10,115200` on dedicated 3-pin JST SH debug header |
| **Root shell**  | adbd over TCP 5555 on ethernet (`adb connect <ip>:5555 && adb root`) |
| **CPU governor**| `performance` (baked into kernel cmdline) |
| **Files app**   | `CarDocumentsUI` (automotive variant, in system/priv-app) |

## Observed build performance

| Phase | Time |
|---|---|
| VM creation + provisioning | ~2 min (one-time) |
| `repo sync` (168 GB, partial clone) | ~45 min at `-j32` |
| Pi 4 first build | **~10.5 hours** — ccache was inactive, and only 20 vCPUs at the time |
| Pi 5 build (projected) | ~6-9 hours — ccache only 23% warm; 48 vCPUs now |
| `mkimg.sh` | ~2 min |
| Image extract (VM → host) | ~20 s |

## Documentation

| Topic | File |
|---|---|
| **Host & VM performance** — measured vz limits, HVF, storage, writeback tuning | [docs/host-performance-2026-08-14.md](docs/host-performance-2026-08-14.md) |
| Earlier build-tuning research (**read its correction banner first**) | [docs/build-tuning-2026-04-13.md](docs/build-tuning-2026-04-13.md) |
| Upstream research snapshot (AOSP `_r4`, `bp4a`, components)     | [docs/research-2026-04-09.md](docs/research-2026-04-09.md) |
| Chronological session log / context handoff                    | [docs/session-log-2026-04-09.md](docs/session-log-2026-04-09.md) |
| **UART serial console** — Pi 4 ttyS0 vs Pi 5 ttyAMA10          | [docs/uart-config.md](docs/uart-config.md) |
| **Root access over ethernet** — adbd-TCP MVP + dropbear sketch | [docs/ssh-root-access.md](docs/ssh-root-access.md) |
| Lima VM management                                             | [docs/lima-setup.md](docs/lima-setup.md) |
| Canonical build commands (run by hand if you must)             | [docs/build-commands.md](docs/build-commands.md) |
| Analysis of the user's older `RPi_AAOS16` framework            | [docs/rpi-aaos16-framework-analysis.md](docs/rpi-aaos16-framework-analysis.md) |
| All external sources                                           | [docs/sources.md](docs/sources.md) |
| **Deferred work / TODOs** (userdata auto-resize, etc.)         | [docs/todo.md](docs/todo.md) |
| Upstream file snapshots (ground truth)                         | [reference/README.md](reference/README.md) |
