# Lima VM — AAOS Builder

A single Lima VM does all the heavy AOSP building.

**Where it lives (changed 2026-08-14):** the instance directory — disk,
logs, ssh keys, instance metadata — is at
`/Volumes/stuff/virtual-machines/lima/aaos-builder`, the machine's shared
lima home, alongside the other Lima instances on this Mac. It used to live
at `$AAOS_ROOT/lima`; that directory has been removed, so there is exactly
one lima home on this machine.

`scripts/env.sh` exports `LIMA_HOME` for you. Override with
`AAOS_LIMA_HOME` if you need to point at a scratch instance:

```bash
source scripts/env.sh          # LIMA_HOME=/Volumes/stuff/virtual-machines/lima
AAOS_LIMA_HOME=/tmp/lima-test source scripts/env.sh
```

The project layout (`out/`, `scripts/`, `overlays/`, `docs/`) still lives
under `$AAOS_ROOT`, and the VM's mounts still point there — only the
instance directory moved.

## Why a VM

- macOS APFS is case-insensitive by default; AOSP refuses to build on it.
  A Linux guest with ext4 is the simple fix.
- AOSP build toolchain is Linux-only (bionic linker, prebuilts, etc.).
- The raspberry-vanilla `*-mkimg.sh` scripts rely on `dosfstools`,
  `kpartx`, `mtools`, and other Linux utilities.

## VM specs

Live config is `$LIMA_HOME/aaos-builder/lima.yaml`;
`templates/aaos-builder.yaml` is the definition used for *fresh* VMs.
Keep the two in sync when you change resources.

| | |
|---|---|
| Driver       | `qemu` + HVF (`-machine q35,accel=hvf`)      |
| Guest OS     | Ubuntu 22.04 LTS cloud image (amd64), kernel 5.15 |
| vCPUs        | **48** (was 20, then 24)                     |
| Memory       | **200 GiB** (was 192 GiB)                    |
| Disk         | 600 GiB sparse — guest sees 582 GB ext4      |
| cpuType      | `host,-avx512vl,-pdpe1gb,+invtsc`            |
| LIMA_HOME    | `/Volumes/stuff/virtual-machines/lima`       |
| Containerd   | disabled                                     |
| Networking   | default user-mode (slirp); socket_vmnet block disabled |

The host has 24 physical / 48 logical cores and 240 GiB RAM. At 48 vCPU /
200 GiB the VM is using essentially all of it, leaving ~40 GiB for macOS.
**If the Mac becomes unusable during builds, drop `cpus` to 24** — that
costs only ~3-5% build throughput.

### Driver choice: QEMU, and why not vz

Earlier revisions of this doc said "vz is Apple Silicon only" and that QEMU
on Intel means "no hardware virtualisation passthrough" with "~20-30%
overhead vs bare metal." **Both claims are wrong.**

- `accel=hvf` *is* hardware virtualisation (Hypervisor.framework, the same
  VT-x path vz uses). Measured 47.7x parallel scaling across 48 vCPUs.
- `vz` does run x86_64 guests on this Intel Mac. Its real limitation is a
  36-bit guest physical address space: RAM caps at 64 GiB, and larger
  requests **silently** produce a ~3 GiB guest while `limactl list` still
  reports the requested size.

Full measurements: [host-performance-2026-08-14.md](host-performance-2026-08-14.md).

### AVX-512 mask is mandatory

Do not remove `-avx512vl` from `cpuType`. Tried on 2026-04-13; the guest
kernel panics at boot (`invalid opcode at raid6_avx5124_gen_syndrome`).
HVF here advertises AVX-512 in CPUID but will not execute EVEX-prefixed
instructions.

## Mounts

Host ↔ guest shares, all under `$AAOS_ROOT`:

| Host path                              | Guest path     | Writable |
|----------------------------------------|----------------|----------|
| `out/`                                 | `/mnt/out`     | yes      |
| `scripts/vm/`                          | `/mnt/scripts` | no       |
| `overlays/`                            | `/mnt/overlays`| no       |

**The AOSP source tree is NOT on a host mount.** Keeping it inside the
guest's ext4 avoids 9p overhead and sidesteps case-sensitivity issues.

## Lifecycle

| Action | Command |
|---|---|
| Check host is ready       | `./scripts/00-check-host.sh` |
| Create + start VM         | `./scripts/01-create-vm.sh` |
| Status                    | `./scripts/vm-status.sh` |
| Interactive shell         | `./scripts/vm-shell.sh` |
| Stop VM (state preserved) | `./scripts/vm-stop.sh` |
| Restart VM                | `./scripts/01-create-vm.sh` (idempotent) |
| **Destroy VM + all data** | `./scripts/vm-destroy.sh` (requires typing `DESTROY`) |

Never `pkill -9 qemu-system-x86_64` — HVF can leak vCPU threads and require
a host reboot.

## Provisioning

On first boot, cloud-init runs two provision scripts embedded in the YAML:

- **system mode:** installs AOSP build prereqs (`git bison flex gperf
  openjdk-17-jdk ccache ...`), drops the Google `repo` tool into
  `/usr/local/bin`, raises `nofile` and `inotify` limits.
- **user mode:** creates `~/aosp`, sets a default git identity.

Provisioning is **idempotent** — rerunning `01-create-vm.sh` on an existing
VM just starts it; it does not re-provision.

Note that the ccache environment baked into `~/.bashrc` by provisioning is
**not** what the build uses. Ubuntu's `.bashrc` returns early on
non-interactive shells, so `scripts/vm/build-aaos.sh` exports
`USE_CCACHE` / `CCACHE_EXEC` / `CCACHE_DIR` itself. See the ccache section
in `CLAUDE.md`.

**Fixed 2026-08-22:** provisioning used to export `CCACHE_DIR=$HOME/.ccache`
and run `ccache -M 200G` against it. That path is unusable by the build
(Soong's nsjail sandbox mounts `/` read-only), so the cap was being applied
to a cache no build ever touched, and an interactive `ccache -s` in the VM
reported that empty cache rather than the real one. Provisioning now exports
`$HOME/aosp/out/.ccache`, matching `build-aaos.sh`, and no longer sets a cap
(`build-aaos.sh` owns it).

If provisioning fails:

```bash
limactl shell aaos-builder sudo cloud-init status --long
limactl shell aaos-builder sudo journalctl -u cloud-final --no-pager -n 200
```

## Guest tunables applied 2026-08-14

| Setting | Value | Where |
|---|---|---|
| `vm.dirty_bytes` | 4 GiB | `/etc/sysctl.d/99-aosp-perf.conf` |
| `vm.dirty_background_bytes` | 1 GiB | same |
| `read_ahead_kb` (vd*) | 512 | `/etc/udev/rules.d/60-virtio-readahead.rules` |
| `nofile` soft+hard | 1048576 | `/etc/security/limits.conf` |

The dirty-page limits matter most: kernel defaults are *ratios*, which on a
196 GiB guest meant buffering ~39 GiB of dirty pages before hard-throttling
— a ~41 s stall at this disk's 958 MB/s write speed.

## Disk sizing

AOSP tree after full sync is ~168 GB; `out/` for one target is ~127 GB;
ccache is capped at 200 GB (currently 8.3 GB). Ubuntu base + tools: ~20 GB.

**Raised to 800 GiB on 2026-08-22.** The full commitment is
20 + 168 + (127 × 2) + 200 ≈ **642 GB**, against the ~582 GB the guest saw
at the old 600 GiB setting — it did not fit, and the shortfall would only
have shown up late in the Pi 5 build once ccache had grown past ~8 GB.
Remember ccache lives *inside* `out/`, so it competes with the build tree
for the same budget. At 800 GiB the guest sees ~776 GB, leaving ~134 GB of
slack. The qcow2 is sparse and `/Volumes/stuff` has 1.3 TiB free, so the
extra capacity is not consumed until it is used.

Lima can only **grow** this value — never shrink it. The grow takes effect
on the next `limactl start`; check `df -h /` in the guest afterwards to
confirm the partition expanded.

The disk image is sparse, so host usage tracks what's actually stored
inside the VM, not the 600 GiB ceiling.

## Recovering after macOS reboot

The VM survives macOS reboots because its state is on the external APFS
volume. After a reboot:

```bash
cd /Volumes/stuff/rpi/aaos
./scripts/01-create-vm.sh        # starts the existing instance
```

If `/Volumes/stuff` is not mounted, `LIMA_HOME` points at nothing and
`limactl` will report no instances — mount the volume first.

## Known gotchas

- **SSH ControlPersist.** Lima's `ssh.config` sets `ControlMaster auto` /
  `ControlPersist yes`, so `limactl shell` reuses an existing connection.
  Session-scoped guest changes (PAM limits, etc.) won't appear until you
  force a reconnect:
  `ssh -F "$LIMA_HOME/aaos-builder/ssh.config" -O exit lima-aaos-builder`
- **socket_vmnet is not installed** on this host any more, so the
  `networks: [{lima: shared}]` block is commented out in `lima.yaml` — with
  it enabled the VM fails to start. No proven throughput benefit anyway.
- **Do not** put `$HOME/aosp` on `/mnt/out`. AOSP's symlink-heavy checkouts
  crawl over 9p.
- **Do not** set `containerd.system: true` — it slows first boot and nothing
  we build needs it.
- If the VM dies mid-sync, rerun `02-sync-aosp.sh`; `repo sync` is resumable.
- If `limactl` complains that `LIMA_HOME` isn't set, `source scripts/env.sh`
  first (the numbered scripts do this automatically).
