# Host & VM performance — measurements, 2026-08-14

Everything here was **measured on this host**, not inferred from docs. Where
it contradicts `build-tuning-2026-04-13.md`, this file wins — that one is
desk research, this one is instrumentation.

Host: Mac Pro 2019 (MacPro7,1), Xeon W-3265 24c/48t, 240 GiB RAM,
macOS 26.6.1 (25G76), Lima 2.2.0, QEMU 11.1.0.
Guest: `aaos-builder`, Ubuntu 22.04.5, kernel 5.15.0-174.

---

## 1. vz is not "Apple Silicon only" — it is 64 GiB-capped, and fails silently

The repo's older docs assert that Virtualization.framework cannot run x86_64
guests on an Intel Mac. That is false. `vz` boots an x86_64 Ubuntu guest here
without complaint.

What actually breaks is memory. VZ builds a **36-bit guest physical address
space** (2^36 = 64 GiB). Above that the request is not rejected — it is
silently discarded and the guest comes up with ~3 GiB.

Measured, one boot per row, reading `MemTotal` and the kernel's `last_pfn`:

| `memory:` requested | Guest `MemTotal` | `last_pfn` | Result |
|---|---|---|---|
| 16 GiB  | 15.6 GiB | `0x440000`  | ok |
| 32 GiB  | 31.3 GiB | `0x840000`  | ok |
| 48 GiB  | 47.0 GiB | `0xc40000`  | ok |
| 60 GiB  | 58.8 GiB | `0xf40000`  | ok |
| 63 GiB  | 61.8 GiB | `0x1000000` | ok — exactly 2^36 bytes |
| **64 GiB**  | **2.9 GiB** | `0xc0000` | **silent fallback** |
| 96 GiB  | 2.9 GiB  | `0xc0000`   | silent fallback |
| 128 GiB | 2.9 GiB  | `0xc0000`   | silent fallback |
| 200 GiB | 2.9 GiB  | `0xc0000`   | silent fallback |

In the failing cases the guest e820 map simply stops at `0xC0000000` — no
region above 4 GiB is created at all. `limactl list` still reports the
requested size, so **the VM looks correctly configured while running with 3 GiB.**

The framework itself does not advertise this limit. Querying it directly:

```swift
VZVirtualMachineConfiguration.maximumAllowedMemorySize  // 257698037760 (240 GiB)
VZVirtualMachineConfiguration.maximumAllowedCPUCount    // 64
```

It claims 240 GiB. It delivers 64.

**Consequence:** `vmType: qemu` is correct, but if anyone ever "fixes" the VM
by switching to vz for speed, the build will get 3 GiB and thrash. Keep the
explanatory comment in `lima.yaml`.

## 2. QEMU+HVF is hardware virtualisation, not emulation

Docs in this repo describe "~20-30% emulation overhead" and "no hardware
virtualisation passthrough like Apple Silicon's vz." Both are wrong.

The running command line contains:

```
-machine q35,accel=hvf
-cpu host,-avx512vl,-pdpe1gb,+invtsc
-smp 48,sockets=1,cores=48,threads=1
-m 204800
```

`accel=hvf` is Hypervisor.framework — the same hardware VT-x path vz uses.
Parallel scaling measured across 48 vCPUs (48 concurrent `openssl speed`
processes): **17.9 s wall for 14 m 14 s of CPU time = 47.7x**. That is not
emulation.

Real overheads that do exist: virtio block/9p I/O, and the mandatory AVX-512
mask costing ~1-3% on clang-heavy phases.

## 3. Storage ceiling

Measured inside the guest against the virtio-blk root disk, 2 GiB, `direct`:

| | |
|---|---|
| Read  | **3.6 GB/s** |
| Write | **958 MB/s** |

The backing store is an external **PCIe/NVMe** SSD (`diskutil` reports
Protocol: PCI-Express, Solid State: Yes), so this is a fast path, not USB.
Reads are near-native; writes are the asymmetric side and are what the
writeback tuning below targets.

## 4. Writeback: the biggest free win

The guest was running kernel defaults, which are **ratios of total RAM**:

```
vm.dirty_ratio = 20            # 20% of 196 GiB = ~39 GiB
vm.dirty_background_ratio = 10 # 10% of 196 GiB = ~20 GiB
```

On a 196 GiB guest that means the kernel will accumulate ~39 GiB of dirty
pages before it hard-throttles writers. At the measured 958 MB/s that flush
takes **~41 seconds**, during which writing processes block. Ninja emits
object files in bursts, so this manifests as periodic multi-second-to-minute
freezes late in a build — easily misread as "the build is just slow."

Fixed by switching to absolute limits (`*_bytes` overrides `*_ratio`), sized
to a few seconds of writeback rather than 41:

`/etc/sysctl.d/99-aosp-perf.conf`
```
vm.dirty_background_bytes = 1073741824   # 1 GiB
vm.dirty_bytes            = 4294967296   # 4 GiB
```

Setting these zeroes the corresponding `*_ratio` values — that is expected,
not an error.

## 5. Why 48 vCPUs does not increase OOM risk

Raising `cpus` 24 -> 48 raises `make -j$(nproc)` to `-j48`. The concern is
concurrent `ld.lld`, which peaks around 25 GiB resident.

Soong already bounds this. From this tree,
`build/soong/ui/build/config.go`:

```go
const minMemPerHighmemProcess = 8 * 1024 * 1024 * 1024
...
} else if p := int(c.totalRAM / minMemPerHighmemProcess); p < parallel {
    // If less than 8GB total RAM per process, reduce the number of highmem processes
```

With 196 GiB usable, `p = 24`. So:

| Config | `parallel` | highmem pool |
|---|---|---|
| old: 24 vCPU / 192 GiB | 24 | 24 (no restriction applied) |
| new: 48 vCPU / 200 GiB | 48 | **24** (restriction applies) |

The linker pool is 24 either way. The extra 24 vCPUs only widen the cheap
compile pool. Peak memory is unchanged; there is no new OOM exposure.

What *does* change is host responsiveness: 48 guest vCPUs on 48 host threads
leaves nothing spare for macOS, and only ~40 GiB of RAM. Drop `cpus` back to
24 if the Mac becomes unusable during builds.

## 6. Other tunables applied

| Setting | Was | Now | Rationale |
|---|---|---|---|
| `read_ahead_kb` (vd*) | 128 | 512 | 128 KiB is spinning-media tuning; this device reads at 3.6 GB/s and AOSP streams large prebuilts/jars. Persisted via udev rule. |
| `nofile` soft/hard | 65536 | 1048576 | `-j48` opens far more fds than `-j24`. |
| I/O scheduler | `none` | `none` | Already correct for virtio-blk — left alone. |
| `fs.inotify.max_user_watches` | 524288 | 524288 | Already adequate. |

### Not changed, deliberately

- **THP** is `madvise`. Switching to `always` may buy a little on clang/ld but
  can introduce allocation-latency spikes. Measure before changing.
- **swappiness = 60** is irrelevant: the guest has no swap. With no swap and
  196 GiB, a runaway link phase OOM-kills rather than thrashing — which is the
  preferable failure mode here.
- **`-smp` topology** is presented as `cores=48,threads=1`, hiding the fact
  that these are 24 physical cores x 2 SMT threads. The guest scheduler
  therefore cannot prefer distinct physical cores at partial load. Lima exposes
  no `-smp` topology knob, so this is not currently actionable.

## 7. Gotcha: SSH ControlPersist hides guest changes

Lima's `ssh.config` uses `ControlMaster auto` + `ControlPersist yes`. After
changing PAM limits, a fresh `limactl shell` still reported the **old**
`nofile` value, because it reused the pre-existing multiplexed master. A
direct login shell (`sudo -u "$USER" bash -lc 'ulimit -n'`) showed the new
value immediately.

Force a reconnect before concluding a session-scoped change didn't work:

```bash
ssh -F "$LIMA_HOME/aaos-builder/ssh.config" -O exit lima-aaos-builder
```

## 8. Remaining opportunities (not done)

1. **ccache is only 8.3 GB / 23% hit.** Nothing to tune — it just needs more
   builds. The Pi 5 build will roughly double its usefulness.
2. **Separate disk for ccache.** Only safe if mounted *inside* `~/aosp/out/.ccache`
   so it stays within nsjail's RW bind. Needs verification that nsjail follows
   the submount. Would decouple cache writes from `out/` writes on a device
   whose write path is the slow side (958 MB/s).
3. **Guest kernel 5.15** — a 6.x HWE kernel has better virtio and scheduler
   behaviour. Low priority; a distro upgrade mid-project is a bigger risk than
   the gain.
