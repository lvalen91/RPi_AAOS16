# Session log — 2026-04-09

Chronological record of what was researched, decided, and built in
the session that created this workspace. Useful as a context handoff
for the next session.

> **Historical snapshot — do not treat as current config.** Written
> 2026-04-09. Superseded specifics: the VM is now 48 vCPU / 200 GiB (not
> 20 / 192), `LIMA_HOME` is `/Volumes/stuff/virtual-machines/lima` (not
> `$AAOS_ROOT/lima`), ccache is capped at 200 GB and lives at
> `$OUT_DIR/.ccache` (not 50 GB in `~/.ccache`), and the note that "vz is
> Apple Silicon only" is wrong — see
> [host-performance-2026-08-14.md](host-performance-2026-08-14.md).
> For current state read `CLAUDE.md`.

## Goal

Build **Android Automotive OS 16** for **Raspberry Pi 4 and Raspberry
Pi 5** from AOSP source, on a **2019 Intel Mac Pro**, with all
workspace state — scripts, docs, Lima VM qcow2, built images — under
a single project folder (`/Volumes/stuff/rpi/aaos`). Files from a
prior successful Pi 5 build in an earlier session were lost; this
time everything must live in the project folder.

## Research phase

Started from two URLs provided by the user:

1. `github.com/noahchalifour/aaos-rpi` — Android 16 wrapper around
   raspberry-vanilla, ships `rpi{4,5}-mkimg.sh`, all 6 lunch targets.
2. `grapeup.com/blog/android-automotive-os-13-on-raspberry-pi-4b` —
   older Android 13 walkthrough with good automotive-service
   commentary.

Key discoveries (see `research-2026-04-09.md`):

- **AOSP tag moved `_r1` → `_r3` → `_r4`** (Android 16 QPR2).
  Google announced a biannual Q2/Q4 AOSP cadence effective 2026; `_r4`
  is the current drop.
- **Lunch suffix changed `bp2a` → `bp4a`** with the `_r4` tag. Any
  guide that still says `bp2a` will fail on the current tree.
- **No automotive-specific device tree in raspberry-vanilla** — the
  `_car` targets apply standard AOSP automotive product config on
  top of the generic `rpi{4,5}` device trees. VHAL is the mock
  emulator.
- **Kernel is precompiled** — `common-android16-6.12-lts`, shipped
  inside `device/brcm/rpi{4,5}-kernel/`; no kernel build step during
  the AOSP build.
- **Component versions:** Linux 6.12.60 (vanilla Dec 2025) / 6.12.67
  (community March 2026), Mesa 25.3.1, libcamera 0.6.0, FFmpeg 8.0.1,
  security patch Dec 5 2025 / Jan 1 2026.
- **Hardware matrix:** Pi 4B / 400 / CM4 and Pi 5 / 500 / CM5 (≥2 GB
  RAM). Broken: CSI cameras. Missing: userdata encryption, GSM/voice,
  real vehicle bus.

## Analysing the user's existing framework

The user also showed `/Users/zeno/Downloads/GitHub/RPi_AAOS16`, an
orchestrator from an earlier session. Full analysis in
`rpi-aaos16-framework-analysis.md`. Summary:

- Pinned to outdated `android-16.0.0_r3` and `bp2a` lunch suffix.
- Hardcoded to `rpi5` only.
- **`UART_DEVICE="ttyAMA0"` in `settings.conf` is wrong for both
  boards** (Pi 4 is ttyS0, Pi 5 is ttyAMA10).
- 52 KB single-file `aaos.sh` orchestrator duplicated by smaller
  modular scripts.
- No macOS/Lima story — assumes a local Linux host.

Decision: supersede with a new, modular workspace at
`/Volumes/stuff/rpi/aaos`.

## UART research (Pi 4 ≠ Pi 5 — important)

Instead of trusting docs, pulled the raw `BoardConfig.mk` and
`boot/config.txt` files from raspberry-vanilla and read them directly.
Saved copies under `reference/raspberry-vanilla/`. Verified:

- **Pi 4:** `BOARD_KERNEL_CMDLINE := console=ttyS0,115200 …` — mini
  UART on **GPIO 14 (TX) / GPIO 15 (RX)**. `enable_uart=1` is in
  default `boot/config.txt`. Uses mini UART (ttyS0), not PL011
  (ttyAMA0). BT stays on PL011.
- **Pi 5:** `BOARD_KERNEL_CMDLINE := console=ttyAMA10,115200 …` —
  the dedicated **3-pin JST SH debug header** near the power button
  (pin 1=RX, 2=GND, 3=TX). **Not GPIO 14/15.** Default Pi 5
  `boot/config.txt` does NOT have `enable_uart=1` and must not — with
  EEPROM ≥ 2025-02-12, adding it would move the console off the
  debug header.

Conclusion: raspberry-vanilla defaults are correct for both boards.
`apply-customizations.sh` verifies but does not override. Full detail
in `docs/uart-config.md`.

## Root-over-ethernet design

User requirement: "root must be available via SSH on ethernet/RJ45"
for troubleshooting a headless Pi.

Decision: **MVP = adbd over TCP 5555**, not dropbear SSH. Rationale:

- `userdebug` builds already allow `adb root` — no new AOSP project.
- `adb connect <ip>:5555 && adb root && adb shell` is strictly
  better than dropbear SSH for troubleshooting (native `logcat`,
  `bugreport`, file transfer).
- Ethernet DHCP on eth0 is already started at boot by AAOS's
  `EthernetService` in the raspberry-vanilla default.
- `apply-customizations.sh` injects `persist.adb.tcp.port=5555`,
  `service.adb.tcp.port=5555`, `persist.sys.ethernet.enable=1` into
  `device/brcm/rpi{4,5}/system.prop`.

Full dropbear path sketched in `docs/ssh-root-access.md` as a
follow-up if needed.

## Lima VM design

Host: 2019 Intel Mac Pro, 24 physical / 48 logical cores, 240 GiB
RAM, Lima 2.1.0 already installed. External APFS volume
`/Volumes/stuff` with 1.4 TiB free. Intel → QEMU driver only (vz is
Apple Silicon only).

VM template (`templates/aaos-builder.yaml`):

- Ubuntu 22.04 LTS cloud image, amd64
- **20 vCPUs** (leaves 4 for macOS)
- **192 GiB RAM** (leaves ~48 GiB for macOS)
- **600 GiB sparse qcow2**
- `LIMA_HOME=$AAOS_ROOT/lima` so all VM state is inside the project
  folder (not `~/.lima`) — guaranteeing nothing is lost on a macOS
  reinstall or a Lima upgrade
- Host mounts: `out/` (rw) for image handoff, `scripts/vm/` (ro),
  `overlays/` (ro)
- AOSP source stays **inside** the guest qcow2 (`~/aosp`) — not on
  any host mount — to avoid 9p/sshfs overhead and case-sensitivity
  issues
- cloud-init provisioning installs all AOSP 16 build deps + `repo`
  + OpenJDK 17 + ccache (50 GB cap)

## Workspace layout (final)

```
/Volumes/stuff/rpi/aaos/
├── README.md                  ← top-level index
├── docs/                      ← everything we know
│   ├── research-2026-04-09.md        ← upstream pins, component versions
│   ├── rpi-aaos16-framework-analysis.md
│   ├── uart-config.md                ← Pi 4 / Pi 5 serial console
│   ├── ssh-root-access.md            ← root over ethernet
│   ├── lima-setup.md                 ← VM management
│   ├── build-commands.md             ← canonical AOSP commands
│   ├── sources.md                    ← bibliography
│   └── session-log-2026-04-09.md     ← this file
├── reference/                 ← upstream file snapshots (read-only)
│   └── raspberry-vanilla/
│       ├── manifest_brcm_rpi.xml
│       ├── remove_projects.xml
│       ├── rpi4/{BoardConfig.mk, boot-config.txt, device.mk}
│       └── rpi5/{BoardConfig.mk, boot-config.txt, device.mk}
├── templates/aaos-builder.yaml
├── scripts/                   ← host-side orchestration
│   ├── env.sh
│   ├── 00-check-host.sh
│   ├── 01-create-vm.sh
│   ├── 02-sync-aosp.sh
│   ├── 03-build.sh
│   ├── 04-extract-image.sh
│   └── vm/                    ← in-VM scripts (mounted at /mnt/scripts)
│       ├── sync-aosp.sh
│       ├── build-aaos.sh
│       ├── apply-customizations.sh
│       └── extract-image.sh
├── overlays/                  ← custom manifests, init.rc, SSH keys (opt.)
├── lima/                      ← LIMA_HOME — VM state lives here
└── out/                       ← built images land here
```

## State at end of session (2026-04-09)

- Project scaffolded, all scripts `bash -n` clean, Lima template
  `limactl validate` OK.
- VM **created and running**: `aaos-builder`, Ubuntu 22.04.5 jammy,
  repo 2.54, OpenJDK 17.0.18, ccache 4.5.1, 20 CPU, 192 GiB RAM,
  600 GiB disk, SSH on 127.0.0.1:49463.
- `~/aosp` staged in the guest, ready for `repo init`.
- **No AOSP sync yet** — next step is `./scripts/02-sync-aosp.sh`
  which will pull `android-16.0.0_r4` + raspberry-vanilla (~100-150
  GB, 1-3 h).
- **No build yet** — after sync, `./scripts/03-build.sh pi4` and/or
  `pi5`.

## State at end of session (2026-04-10)

- **Pi 4 build: COMPLETE.** `out/RaspberryVanillaAOSP16-20260410-rpi4_car.img` (14 GB) on host.
  - Lunch: `aosp_rpi4_car-bp4a-userdebug`
  - Customizations baked in: adbd-TCP 5555, cpufreq=performance, CarDocumentsUI
  - Build time: ~10.5 hours (first build, zero ccache, QEMU on Intel)
  - Build log: `logs/build-pi4-20260409-162010.log` (202K lines)
- **Pi 5 build: NOT STARTED.** User wants Pi 4 confirmed on hardware first.
  - ccache (200 GB) is warm from Pi 4; expect ~4-6 h for Pi 5.
- **Lima VM: STOPPED** — `aaos-builder`, 265 GB used in qcow2, AOSP tree 168 GB.
  Resume with `./scripts/01-create-vm.sh` (~30 s).
- **socket_vmnet:** installed and wired (`/opt/socket_vmnet/bin/`, `/etc/sudoers.d/lima`).
  No proven benefit over slirp for this workload; kept because it's already set up.
- **9p cache fix:** scripts now pushed to `/tmp/aaos-scripts/` via `vm_push_scripts`
  (tar-over-stdin) instead of executing from the 9p mount.

### Performance data

| Phase | Duration | Notes |
|---|---|---|
| VM creation + cloud-init provisioning | ~2 min | One-time; preserved across restarts |
| `repo sync` (168 GB total, partial clone) | ~45 min | -j32, `android-16.0.0_r4`, resumed after SIGKILL damage + 3 recovery syncs |
| Pi 4 first build (zero ccache) | **~10.5 h** | QEMU on Intel adds ~20-30% vs bare metal; `make -j20` inside 20-vCPU VM |
| `rpi4-mkimg.sh` | ~2 min | 15.36 GB image created |
| Image extract (VM → host via 9p) | ~20 s | 14 GB via `/mnt/out` |

### Bugs fixed during the session

1. **`pi4` vs `rpi4` naming** — all scripts accepted `pi4` but device trees / lunch targets use `rpi4`. Fixed: scripts now canonicalize both to `$BOARD`.
2. **`set -u` + AOSP `envsetup.sh`** — AOSP references `$TOP` without setting it. Fixed: `build-aaos.sh` uses `set -eo pipefail` (no `-u`).
3. **`set -e` in process substitution** — `ls` glob miss killed the subshell before the second `ls` ran. Fixed: `|| true` on each `ls`.
4. **9p cache coherency** — host edits to `scripts/vm/*.sh` weren't visible in VM. Fixed: `vm_push_scripts` tars scripts into `/tmp/aaos-scripts/` inside the guest.
5. **socket_vmnet brew symlink** — Lima refuses symlinks in the binary path. Fixed: binary copied to `/opt/socket_vmnet/bin/` (non-symlink, root-owned).
6. **socket_vmnet sudoers group** — Lima couldn't read `/etc/sudoers.d/lima` (root:wheel 0440). Fixed: chgrp to admin.
7. **`/private/var/run/lima` group** — needed `daemon` group writability. Fixed: `chgrp daemon + chmod 0775`.
8. **ccache reset on VM restart** — instance yaml had `ccache -M 50G` in user provisioning (re-runs each boot). Fixed: changed to 200G.
9. **Broken work trees from SIGKILL** — 10 projects left half-initialized. Fixed: `rm -rf` work tree + `.repo/projects/*.git`, then resync.

### What didn't matter (wasted effort)

- **socket_vmnet setup** (~20 min): no proven throughput improvement over slirp; both upstream-bound.
- **-j12 → -j32 bump**: unclear benefit due to measuring different sync phases.
- **Cloudflare / tele2 speedtests**: wrong URLs / single-stream, no useful signal.
- **First `setup-vmnet.sh`**: chowned brew's Cellar (wrong approach), had to redo.

## Open items / next session

1. **Validate Pi 4 on hardware** — flash, boot, check `/proc/cmdline` for governor,
   verify CarDocumentsUI launches, test adb-over-ethernet.
2. **Build Pi 5** — `./scripts/03-build.sh pi5` after Pi 4 confirmed.
3. **Dropbear SSH** — if adbd-TCP proves insufficient. See `docs/ssh-root-access.md`.
4. **Port `settings.conf` knobs** from RPi_AAOS16 (display density, partition sizes,
   audio routing) as proper overlay files.
5. **Userdata auto-resize** — shrink image + first-boot expand. See `docs/todo.md`.
6. **Diff guard for reference/** — when bumping AOSP tag, refresh snapshots and diff.
