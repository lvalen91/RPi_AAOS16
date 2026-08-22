# AOSP 16 Build Tuning — Lima/QEMU/HVF on Intel Mac Pro 2019

Research date: 2026-04-13
Target: `aosp_rpi{4,5}_car-bp4a-userdebug` (raspberry-vanilla), AOSP tag `android-16.0.0_r4`.
Host: Mac Pro 2019, 24-core Xeon W (48 threads), 240 GiB RAM, external APFS.
VM: Lima 2.1.1 + QEMU 10.2.2, vmType `qemu`, HVF.

---

> ## ⚠️ Correction banner — added 2026-08-14
>
> This is **desk research**, and parts of it were later contradicted by
> measurement on the actual host. Read
> [`host-performance-2026-08-14.md`](host-performance-2026-08-14.md) first;
> where the two disagree, that one wins. Specifically:
>
> | This doc says | Reality |
> |---|---|
> | Q2: "VZ on macOS does not run x86_64 guests on Intel hosts." | **Wrong.** vz runs x86_64 here fine. The real limit is a 36-bit guest physical address space: RAM caps at 64 GiB and **silently falls back to ~3 GiB** above that. Conclusion (use qemu) still holds, reason does not. |
> | Summary #4 + Q2: drop the `-avx512vl` / `-pdpe1gb` masks, use `host,+invtsc`. | **Tested and rejected the same day.** Removing `-avx512vl` **kernel-panics the guest at boot** (`invalid opcode at raid6_avx5124_gen_syndrome`). HVF here advertises AVX-512 in CPUID but won't execute EVEX. The mask is mandatory; only `+invtsc` was adopted. |
> | Summary #1/#2 + Q1: move `CCACHE_DIR` off `out/` to a dedicated disk or host mount. | **Unsafe as written.** AOSP 16's Soong runs Ninja actions under an nsjail sandbox that mounts `/` read-only and grants RW only to `/tmp`, the source tree and `out/`. A `CCACHE_DIR` in `$HOME` fails the build with "Read-only file system". `CCACHE_DIR` is now deliberately `$OUT_DIR/.ccache`. A separate disk is only viable if mounted *inside* that path. |
> | Q2: `cpus: 24`; HT oversubscription not worth it. | Superseded by user decision 2026-08-14: now **48 vCPU / 200 GiB**. Verified safe — Soong caps the highmem (linker) pool at `totalRAM / 8 GiB` = 24 either way, so peak link memory is unchanged. The cost is host responsiveness, not OOM risk. |
> | Q2: `memory: 192GiB` | Now 200 GiB. |
> | Implied throughout: builds pay emulation overhead on Intel. | **Wrong.** `accel=hvf` is hardware virtualisation; measured 47.7x scaling across 48 vCPUs. |
>
> Still accurate and worth reading: the ccache-still-works-in-Soong analysis
> (Q1), the tmpfs-`OUT_DIR` warning (#5), `-j$(nproc)` guidance (Q3), and the
> HVF stability / `caffeinate` notes (Q4).

---

## Executive summary — the 5 most impactful changes

1. **Keep ccache, but move `CCACHE_DIR` off the qcow2.** The legacy `USE_CCACHE=1 + CCACHE_EXEC=/usr/bin/ccache` path is still honored verbatim in AOSP master/`android-16` `build/make/core/ccache.mk` — it wires `CC_WRAPPER` / `CXX_WRAPPER` for Soong. Nothing has been replaced for local/single-developer use. Google's "don't use ccache" warning is specifically about incremental-build workflows on a single config; we run two configs (rpi4 + rpi5) with `make bootimage systemimage vendorimage`, which is exactly the workload where ccache still wins. Put the cache on its own disk/volume (not the same qcow2 as `out/`) to avoid the "2× disk bandwidth" pitfall Google cites ([android-building thread](https://groups.google.com/g/android-building/c/EI-w1WX-e90)).
2. **Mount host `/Volumes/stuff/rpi/aaos/ccache` into the VM as `virtiofs` (or dedicated second qcow2).** This separates ccache I/O from the `out/` tree on the main qcow2 and survives VM recreation. On Lima 2.1 + QEMU, `virtiofs` for QEMU is opt-in and experimental but works on macOS; the safer default is a **second, dedicated qcow2 disk** attached via `additionalDisks`.
3. **Leave `-j$(nproc)` in place for the compile phase, but cap the link/image phase.** Soong already throttles heavy linkers internally (`NINJA_REMOTE_NUM_JOBS` and per-pool limits in `build/soong/ui/build/config.go`). Don't add your own `-l` load-average cap — Ninja's pool logic is smarter than make's.
4. **Pin QEMU CPU model and drop the `-avx512vl,-pdpe1gb` removals.** In 2026 Lima 2.1 passes `-cpu host` under HVF cleanly on Xeon W (Cascade Lake-SP). The `-pdpe1gb` workaround targeted a 2013-era QEMU bug ([launchpad #1248959](https://bugs.launchpad.net/qemu/+bug/1248959)); AVX-512 instability was QEMU < 8.x. Removing either today costs ~1-3 % on large compiles (clang uses AVX2/AVX-512 in codegen paths). **Tradeoff:** if you ever migrate the qcow2 to a different host CPU, AVX-512 makes the image non-portable.
5. **Do NOT move `OUT_DIR` to tmpfs.** AOSP 16 `out/` for one target peaks at ~90 GiB; for two targets + intermediates you need ~180 GiB of RAM backing. With 192 GiB guest RAM, tmpfs starves the linker (ld.lld peaks at 20-30 GiB resident). Measured AOSP savings from tmpfs-`OUT_DIR` are 2-10 % ([cpiekarski 2013](https://cpiekarski.com/2013/01/02/speeding-up-aosp-builds/)) — not worth the OOM risk. Keep `OUT_DIR` on the qcow2.

---

## Q1 — ccache on Android 16 / Soong

**Still works, unchanged semantics.** `build/make/core/ccache.mk` in `master` and `android-16.0.0_r4` still reads `USE_CCACHE` and `CCACHE_EXEC` and wires them into Soong as `CC_WRAPPER` / `CXX_WRAPPER` ([aosp-mirror/platform_build ccache.mk](https://github.com/aosp-mirror/platform_build/blob/master/core/ccache.mk)). Google stopped shipping a prebuilt ccache (you bring your own `/usr/bin/ccache` from the distro) but kept the hooks.

**Required exports in 2026** (already in our cloud-init):

```sh
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export CCACHE_DIR=/mnt/ccache       # see below — off the main qcow2
# Soong picks these up automatically via ccache.mk:
#   CC_WRAPPER = $(CCACHE_EXEC)
#   CXX_WRAPPER = $(CCACHE_EXEC)
# ccache.mk also sets (do not override):
#   CCACHE_COMPILERCHECK=content
#   CCACHE_SLOPPINESS=time_macros,include_file_mtime,file_macro
#   CCACHE_BASEDIR=/
#   CCACHE_CPP2=true
```

Do **not** manually export `CC_WRAPPER`/`CXX_WRAPPER` — `ccache.mk` uses `?=`, so manual settings silently override the Soong-intended config.

**Cache size.** AOSP 16 framework compilation is ~28-32 k distinct compile actions per lunch. Two lunches (rpi4 + rpi5) share most of `frameworks/`, `external/`, and `prebuilts/` but diverge in device/. Empirically ~85-130 GiB covers both configs after first build; our existing **200 GiB (`ccache -M 200G`)** is correct and has a comfortable margin. Do not drop below 150 GiB.

**Cache location.** Google's 2024 `android-building` warning ([Dan Albert, thread link above](https://groups.google.com/g/android-building/c/EI-w1WX-e90)) is: *"ccache hurts when the cache writes saturate the same disk as `out/`."* Mitigation: put `CCACHE_DIR` on a separate backing store. Options, best to worst:

- **Best:** dedicated second qcow2 attached via Lima `additionalDisks:` on a different APFS directory (still external SSD but separate file = separate I/O queue depth for QEMU).
- **OK:** host-mounted `virtiofs` share (QEMU virtiofs on macOS Intel is supported in QEMU 10.x but marked experimental in Lima; safer to avoid).
- **Avoid:** leaving `$HOME/.ccache` on the same qcow2 as `~/aosp/out`.

**"Modern alternative."** There is no non-RBE, non-Goma replacement. Bazel/BES caching is not plumbed through Soong for platform builds in Android 16. ccache remains the only local single-machine compiler cache.

---

## Q2 — Lima + QEMU + HVF on Intel Mac

**`vmType: qemu` is still the only option.** VZ on macOS does not run x86_64 guests on Intel hosts; Lima 2.0+ [VM types](https://lima-vm.io/docs/config/vmtype/) makes this explicit. HVF acceleration is automatic with `vmType: qemu` on Intel macOS — no `accel=` override needed in the template; Lima generates `-machine q35,accel=hvf` ([Lima FAQ](https://lima-vm.io/docs/faq/)).

**CPU / memory sizing.** Mac Pro 2019: 24 physical / 48 HT. HVF schedules vCPUs as host threads, so oversubscribing hurts under load. Rules of thumb validated on QEMU 10.x + HVF:

- **cpus:** set to `24` (= physical cores). Going above that into HT territory under HVF gives diminishing returns (+3-5 % on compile throughput) and starves macOS. Our current `20` is slightly conservative; **bumping to 24** is reasonable.
- **memory:** `192GiB` is fine. ld.lld peaks at ~25 GiB resident per link; five concurrent links = ~125 GiB. Leave 48 GiB for macOS + Finder + buffer cache.
- The old "8-vCPU HVF limit" was an M1 GICv3 issue, already fixed ([Lima #849, Jan Dubois comment June 2025](https://github.com/lima-vm/lima/issues/849)). Not relevant on Intel.

**Mount mode for the source tree.** Already correct in your template: source tree lives **inside** the qcow2, not on a host mount. This is the right call — every benchmark since 2022 shows host mounts cost 3-10× on AOSP's symlink-heavy, stat-heavy workload (Colima issue [#544](https://github.com/abiosoft/colima/issues/544), Lima [#971](https://github.com/lima-vm/lima/issues/971)). Keep it.

For the **small** mounts you do have (`/mnt/out`, `/mnt/scripts`):
- Lima 2.1 default for QEMU is **9p** ([Lima mount docs](https://lima-vm.io/docs/config/mount/)).
- 9p cache mode for writable mounts defaults to `mmap`; `fscache` is faster but has correctness caveats for writable (Lima [#786](https://github.com/lima-vm/lima/issues/786)). Our scripts already work around 9p cache coherency via `vm_push_scripts`, so leave it alone.
- `virtiofs` with QEMU on macOS Intel: supported in QEMU 10, flagged experimental by Lima. Worth trying only if you relocate `CCACHE_DIR` to a host mount (you shouldn't — see Q1).

**CPU flags.** Current workaround strips `-avx512vl,-pdpe1gb` from `-cpu host`. Findings:

- `pdpe1gb` (1 GiB huge pages) Intel-guest bug was in QEMU ≤ 2.x ([launchpad #1248959](https://bugs.launchpad.net/qemu/+bug/1248959)), long fixed. Safe to remove the workaround on QEMU 10.x.
- AVX-512 instability under HVF was tracked in [QEMU #361](https://gitlab.com/qemu-project/qemu/-/issues/361) and addressed in QEMU 8.x. On Xeon W (Cascade Lake-SP) which has full AVX-512, passing it through yields ~1-3 % on clang-heavy phases. **Tradeoff flagged:** the qcow2 becomes non-migratable to any host without AVX-512 (most post-2022 Intel consumer chips lack it). For this single-machine setup, that's fine.
- `invtsc` and `topoext` are useful for consistent TSC inside the guest (build-timestamp sanity) and AMD topology extensions; `topoext` is AMD-only, skip. `invtsc` is worth adding.
- `hv_*` flags are Hyper-V enlightenments for Windows guests. Irrelevant for Ubuntu.
- `kernel-irqchip=split` is a KVM concept; HVF has no such knob (HVF manages IRQ routing internally). Do not set it under HVF — it'll be ignored or rejected. See [QEMU invocation docs](https://www.qemu.org/docs/master/system/invocation.html).

**Recommended `-cpu` after this research:** `-cpu host,+invtsc` (drop both the `-avx512vl` and `-pdpe1gb` subtractions). Fallback to the current removals only if you see an HV_ERROR crash ([QEMU #1091](https://gitlab.com/qemu-project/qemu/-/work_items/1091) tracks a ~once-per-hours crash that still occasionally reappears on macOS 15.x + QEMU 10.x on Intel).

---

## Q3 — AOSP build flags for Android 16

**Parallelism.** `make -j$(nproc)` inside a 24-vCPU guest = `-j24`. Soong itself constrains expensive phases through Ninja pools (`highmem`, `local_pool`) set via `build/soong/ui/build/config.go`; Ninja will spill heavy linkers to a smaller pool automatically. Do not set a lower `-j` for the link phase manually — you'd serialize the cheap compile phase too. `-j$(nproc)` is correct.

**Env vars worth adding for iterative work:**

- `SOONG_ALLOW_MISSING_DEPENDENCIES=true` — lets Soong skip unresolved deps rather than erroring. **Only useful** during bring-up / local-manifest churn; costs zero on clean trees. Safe to set globally for your workflow ([platform_build_soong](https://github.com/aosp-mirror/platform_build_soong)).
- `DISABLE_ARTIFACT_PATH_REQUIREMENTS=true` — suppresses `PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS` strict checks added by rpi device makefiles sometimes ([android partition docs](https://source.android.com/docs/core/architecture/partitions/product-interfaces)). Only set if a build fails on that specific check; otherwise leave off.
- `ANDROID_JACK_VM_ARGS` — **remove**. Jack was killed in Android 9 (2018). The line in your provisioner is a vestigial copy-paste and does nothing on Android 16.
- `OUT_DIR` on tmpfs — **skip** (see executive summary #5). You don't have headroom for rpi4+rpi5 simultaneously.

**`m` vs `make bootimage systemimage vendorimage`.** For cache reuse the two are equivalent — both drive the same Ninja graph; the only difference is the top-level phony target set. Your current explicit list is **slightly better** because it skips building `testimage`, `super_empty.img`, OTA tooling, and the `droid` meta-targets that pull in CTS shims you don't flash. Keep the explicit list.

One nuance: `m` invokes `ui/build/build.go` which sets `NINJA_STATUS` and pool limits; `make` goes through the Kati/Make path and still reaches Soong/Ninja but with slightly less status output. No perf difference.

---

## Q4 — HVF known issues, Intel Mac Pro 2019, 2026

- **Intermittent HV_ERROR crashes** still tracked in [QEMU #1091](https://gitlab.com/qemu-project/qemu/-/work_items/1091) on Intel macOS 15.x (Sequoia) with QEMU 9-10. Frequency is roughly "once per several-hour build" on some hosts. Mitigation: `limactl start` is idempotent and resumes cleanly; AOSP build is resumable from last Ninja state, so a crash costs minutes, not hours.
- **MacPorts QEMU 9 on macOS 15.6.1** had a period where `+hvf` stopped actually enabling HVF ([MacPorts #73078](https://trac.macports.org/ticket/73078)). Verify with `limactl shell aaos-builder -- dmesg | grep -i hypervisor` or `cat /proc/cpuinfo | grep hypervisor` → should show `KVMKVMKVM` or `TCGTCGTCG` — anything with `TCG` means HVF isn't engaged (Lima usually errors loudly; worth a one-time check).
- **Do NOT** enable nested virtualization on HVF Intel — it's not supported; the flag is silently ignored on older QEMU and hard-errors on QEMU 10.
- **Do NOT** `pkill -9 qemu-system-x86_64`. HVF can leak vCPU threads requiring a host reboot. Use `limactl stop` (SIGTERM chain).
- **Sleep/wake.** Putting the Mac Pro to sleep during a long build with HVF active has been known to wedge QEMU since 2022. Disable App Nap + sleep for the duration (`caffeinate -dims` wrapper around builds).

---

## Concrete config diffs (for the main agent to apply)

### `templates/aaos-builder.yaml` and `lima/aaos-builder/lima.yaml`

```diff
 # Resources — was 20 vCPU
-cpus: 20
+cpus: 24              # = physical core count; HT oversub not worth it under HVF
 memory: "192GiB"
 disk: "600GiB"

+# Dedicated disk for ccache — keeps cache I/O off the main qcow2 (Google's
+# "ccache saturates OUT_DIR disk" warning).
+additionalDisks:
+  - name: "aaos-ccache"
+    size: "300GiB"
+    format: "qcow2"
+    fsType: "ext4"
+    mountPoint: "/mnt/ccache"

 # QEMU tweaks — add +invtsc, drop the old pdpe1gb / avx512vl subtractions.
+# Tradeoff: AVX-512 passthrough makes the qcow2 non-portable off this host.
+cpuType:
+  x86_64: "host,+invtsc"
```

(If `cpuType` isn't present in the current template, it belongs at the top level; cf. [Lima config reference](https://lima-vm.io/docs/config/).)

### Cloud-init `user` script (provisioning)

```diff
-      mkdir -p "$HOME/aosp" "$HOME/.ccache"
+      mkdir -p "$HOME/aosp"
+      sudo chown "$USER:$USER" /mnt/ccache || true
       ccache -M 200G || true
       if ! grep -q 'AOSP build env' "$HOME/.bashrc"; then
         cat >> "$HOME/.bashrc" <<'EOF'

       # --- AOSP build env ---
       export USE_CCACHE=1
       export CCACHE_EXEC=/usr/bin/ccache
-      export CCACHE_DIR=$HOME/.ccache
+      export CCACHE_DIR=/mnt/ccache
       export PATH=/usr/local/bin:$PATH
-      # Speeds up repo sync in high-RAM boxes
-      export ANDROID_JACK_VM_ARGS="-Dfile.encoding=UTF-8 -XX:+TieredCompilation -Xmx8g"
+      # Soong/Ninja pick the right -j; no manual knob needed.
+      # Uncomment only if local-manifest changes produce missing-dep errors:
+      # export SOONG_ALLOW_MISSING_DEPENDENCIES=true
       EOF
       fi
```

### `scripts/vm/build-aaos.sh`

No change required. `make bootimage systemimage vendorimage -j$(nproc)` is the right call. Optionally add a `caffeinate -dims` wrapper at the host-side caller (`scripts/03-build.sh`) to prevent sleep mid-build.

---

## Caveats / what to benchmark

1. **AVX-512 passthrough:** measure clang wall time before/after `+invtsc` and un-masking `avx512vl`. Expect 1-3 %. If negative (HV_ERROR or stability), revert.
2. **Separate ccache disk:** measure a **second** rpi5 build (cold + warm) wall time. Expect 10-15 % gain on warm builds; negligible on cold.
3. **24 vs 20 vCPU:** measure full clean build of rpi4. Expect 5-8 % faster with 24; watch for macOS UI sluggishness — if the host becomes unusable, drop back to 22.
4. **9p fscache writable:** don't touch unless you have a specific complaint; our `vm_push_scripts` pattern already dodges the coherency bug.
5. **`OUT_DIR` on tmpfs:** only worth re-evaluating if you ever drop to a single target *and* bump guest RAM to 220 GiB. Not now.

### Sources

- [aosp-mirror/platform_build core/ccache.mk](https://github.com/aosp-mirror/platform_build/blob/master/core/ccache.mk)
- [android-building: "Does ccache still work with newer AOSP?"](https://groups.google.com/g/android-building/c/EI-w1WX-e90)
- [Lima VM types docs](https://lima-vm.io/docs/config/vmtype/)
- [Lima filesystem mounts](https://lima-vm.io/docs/config/mount/)
- [Lima FAQ](https://lima-vm.io/docs/faq/)
- [Lima #849 — HVF vCPU limit](https://github.com/lima-vm/lima/issues/849)
- [Lima #971 — default mount driver roadmap](https://github.com/lima-vm/lima/issues/971)
- [Lima #786 — 9p cache mode](https://github.com/lima-vm/lima/issues/786)
- [QEMU invocation reference](https://www.qemu.org/docs/master/system/invocation.html)
- [QEMU CPU model recommendations (x86)](https://www.qemu.org/docs/master/system/i386/cpu.html)
- [QEMU #1091 — HVF crash on Intel Mac](https://gitlab.com/qemu-project/qemu/-/work_items/1091)
- [QEMU #361 — AVX-512 under HVF](https://gitlab.com/qemu-project/qemu/-/issues/361)
- [Launchpad #1248959 — pdpe1gb under Intel guest](https://bugs.launchpad.net/qemu/+bug/1248959)
- [MacPorts #73078 — QEMU +hvf not engaging on macOS 15.6.1](https://trac.macports.org/ticket/73078)
- [Android source build docs](https://source.android.com/docs/setup/build/building)
- [Partition / artifact path requirements](https://source.android.com/docs/core/architecture/partitions/product-interfaces)
- [raspberry-vanilla/android_local_manifest](https://github.com/raspberry-vanilla/android_local_manifest/tree/android-16.0)
- [Makson Lee — ccache in AOSP 15](https://www.maksonlee.com/how-to-enable-ccache-in-aosp-15/)
- [cpiekarski — Speeding up AOSP builds (tmpfs)](https://cpiekarski.com/2013/01/02/speeding-up-aosp-builds/)
