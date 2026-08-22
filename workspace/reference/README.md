# reference/ — upstream source snapshots

Read-only copies of the upstream files we depend on, captured
**2026-04-09** from `raspberry-vanilla/*` on branch `android-16.0`.
Keep these as **ground truth** for UART / partition / product config
decisions — if our build drifts from upstream, this is what "correct"
looked like at capture time.

These files are **not** consumed at build time. The real build pulls
fresh copies during `repo sync`. This tree exists so we can diff,
audit, and reason about the build without an internet round-trip.

## Layout

```
reference/raspberry-vanilla/
├── README.md                         ← this file
├── README-local_manifest.md          ← raspberry-vanilla/android_local_manifest README
├── README-kernel_manifest.md         ← raspberry-vanilla/android_kernel_manifest README
├── manifest_brcm_rpi.xml             ← the local manifest we add to .repo/local_manifests/
├── remove_projects.xml               ← for shallow-clone flows
├── rpi4/
│   ├── BoardConfig.mk                ← device/brcm/rpi4/BoardConfig.mk  (kernel cmdline!)
│   ├── boot-config.txt               ← device/brcm/rpi4/boot/config.txt (enable_uart etc.)
│   └── device.mk                     ← device/brcm/rpi4/device.mk
└── rpi5/
    ├── BoardConfig.mk                ← device/brcm/rpi5/BoardConfig.mk
    ├── boot-config.txt               ← device/brcm/rpi5/boot/config.txt
    └── device.mk                     ← device/brcm/rpi5/device.mk
```

## Provenance (git-style)

| File | Upstream path | Commit branch |
|---|---|---|
| `manifest_brcm_rpi.xml`       | `raspberry-vanilla/android_local_manifest/manifest_brcm_rpi.xml` | `android-16.0` |
| `remove_projects.xml`         | `raspberry-vanilla/android_local_manifest/remove_projects.xml`   | `android-16.0` |
| `rpi4/BoardConfig.mk`         | `raspberry-vanilla/android_device_brcm_rpi4/BoardConfig.mk`      | `android-16.0` |
| `rpi4/boot-config.txt`        | `raspberry-vanilla/android_device_brcm_rpi4/boot/config.txt`     | `android-16.0` |
| `rpi4/device.mk`              | `raspberry-vanilla/android_device_brcm_rpi4/device.mk`           | `android-16.0` |
| `rpi5/BoardConfig.mk`         | `raspberry-vanilla/android_device_brcm_rpi5/BoardConfig.mk`      | `android-16.0` |
| `rpi5/boot-config.txt`        | `raspberry-vanilla/android_device_brcm_rpi5/boot/config.txt`     | `android-16.0` |
| `rpi5/device.mk`              | `raspberry-vanilla/android_device_brcm_rpi5/device.mk`           | `android-16.0` |

## Key take-aways (see `docs/uart-config.md` for detail)

- **Pi 4 kernel cmdline:** `console=ttyS0,115200` (mini UART on GPIO 14/15).
- **Pi 5 kernel cmdline:** `console=ttyAMA10,115200` (dedicated 3-pin JST SH debug header, *not* GPIO 14/15).
- **Pi 4 config.txt:** has `enable_uart=1` by default.
- **Pi 5 config.txt:** has NO `enable_uart=1` by default — the debug header is routed regardless.
- Partition sizes, SELinux posture (`permissive`), and platform
  (`bcm2711` vs `bcm2712`) are in `BoardConfig.mk`.

## Refreshing this snapshot

When the user bumps the AOSP tag or tracks a new raspberry-vanilla
branch, re-run:

```bash
# from the project root
bash -c '
REF=reference/raspberry-vanilla
BRANCH=android-16.0
for board in rpi4 rpi5; do
  for f in BoardConfig.mk device.mk; do
    curl -fsSL "https://raw.githubusercontent.com/raspberry-vanilla/android_device_brcm_${board}/${BRANCH}/${f}" \
      -o "$REF/${board}/${f}"
  done
  curl -fsSL "https://raw.githubusercontent.com/raspberry-vanilla/android_device_brcm_${board}/${BRANCH}/boot/config.txt" \
    -o "$REF/${board}/boot-config.txt"
done
for f in manifest_brcm_rpi.xml remove_projects.xml README.md; do
  out=$f; [ "$f" = "README.md" ] && out=README-local_manifest.md
  curl -fsSL "https://raw.githubusercontent.com/raspberry-vanilla/android_local_manifest/${BRANCH}/${f}" \
    -o "$REF/${out}"
done
'
```

Then `git diff` (or just `diff -r`) against the previous snapshot to
see what changed upstream.
