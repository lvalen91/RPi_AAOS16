# Build and lab hosts

Two machines, deliberately different roles.

## Mac Pro — `macPro.zcarp`, 192.168.4.233 — **the AOSP build host**

Mac Pro 2019 (MacPro7,1), Xeon W-3265, 24 physical / 48 logical cores, 240 GiB RAM,
macOS 26.6.2. AOSP builds run in a Lima VM here, not on the metal.

- `LIMA_HOME=/Volumes/stuff/virtual-machines/lima`, instance **`aaos-builder`**
- qemu + HVF, **48 vCPU / 200 GiB / 800 GiB disk**, Ubuntu 22.04 guest
- AOSP tree is `~/aosp` **inside the VM** (~300 GB)
- Workspace on the host: `/Volumes/stuff/rpi/aaos` (this directory, vendored into the repo)

**Why qemu and not vz:** VZ builds a 36-bit guest physical address space, so guest RAM
caps at 64 GiB — and any larger request *silently* falls back to ~3 GiB while
`limactl list` still reports the number you asked for. qemu+HVF reaches the full
200 GiB at hardware-virtualisation speed.

**Gotcha:** `limactl` is not on the PATH of a non-interactive ssh shell. Scripts invoked
remotely need `PATH=/usr/local/bin:...` or `03-build.sh` fails with "VM not found".

Host mounts, seen from inside the VM:

| Host | In VM | Mode |
|---|---|---|
| `/Volumes/stuff/rpi/aaos/out` | `/mnt/out` | rw — **this is how files leave the VM** |
| `/Volumes/stuff/rpi/aaos/scripts/vm` | `/mnt/scripts` | ro |
| `/Volumes/stuff/rpi/aaos/overlays` | `/mnt/overlays` | ro |

## MSI — `msi.zcarp`, 192.168.4.239 — **native Linux, when a VM will not do**

Fedora Linux 44 Workstation, kernel 7.1.9, **16 cores / 62 GiB RAM**, 861 GB free on NVMe.

Not the AOSP build host — the Mac Pro has three times the cores and three times the RAM,
and AOSP wants both. This is here for the things a VM is bad at or a Mac cannot do at all:

- real USB device access (OCBM / CCPA / gadget work) without passthrough games
- running the CarPlay stack against actual Linux kernel behaviour
- exercising the repo's Linux-native build path (`aaos.sh`, `scripts/`) which has only
  ever been used for Pi 5

**Currently installed:** git, python3, cc, podman.
**Missing for an AOSP or Android workflow:** `adb`, `fastboot`, `repo`, `java`, `rustc`/`cargo`.

Note Fedora is not an AOSP-supported host distro — the official builds target Ubuntu, and
the numbered scripts in `../scripts/` assume the Lima/Ubuntu guest. Treat an AOSP build
here as a porting job, not a drop-in.

## Access

Both accept password SSH as `zeno` and both need **pubkey auth explicitly disabled** or
the connection fails before it offers a password:

```sh
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password zeno@<host>
```
