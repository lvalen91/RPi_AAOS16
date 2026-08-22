# Logging & Monitoring

All long-running host scripts now persist their output to
`$AAOS_ROOT/logs/` so you can leave a build unattended, come back
hours later, and still see exactly what happened. You can also tail
the in-progress log from a second terminal without disturbing the
build.

## How it works

Every numbered host script calls `start_log <tag>` right after
sourcing `env.sh`. `start_log` (defined in `scripts/env.sh`):

1. Opens `logs/<tag>-<YYYYmmdd-HHMMSS>.log`
2. Points `logs/latest-<tag>.log` and `logs/latest.log` symlinks at
   the new file
3. Redirects the rest of the script's stdout + stderr to both the
   terminal *and* the log (via a `tee` process substitution)
4. Writes a start marker with timestamp and pid
5. Installs an `EXIT` trap that writes an end marker with the exit
   code — so you can tell at a glance whether a finished log is a
   success or a failure

Log files are plain text, one per invocation, never rotated or
deleted automatically. ANSI colour codes are skipped when the output
is not a tty, so log files are clean.

## Tags

| Script                          | Tag          | Typical size |
|---------------------------------|--------------|--------------|
| `01-create-vm.sh`               | `create-vm`  | small (a few KB) |
| `02-sync-aosp.sh`               | `sync-aosp`  | **big** — hundreds of MB over 1-3 h |
| `03-build.sh pi4`               | `build-pi4`  | **big** — tens of MB over 2-3 h |
| `03-build.sh pi5`               | `build-pi5`  | **big** — tens of MB over 2-3 h |
| `04-extract-image.sh pi4\|pi5`  | `extract-pi4` / `extract-pi5` | small |

## Watching a run live

From a second terminal, while a build is running in the first:

```bash
cd /Volumes/stuff/rpi/aaos

# Follow the newest log of any kind (usually what you want)
./scripts/logs-tail.sh

# Or follow a specific tag
./scripts/logs-tail.sh sync-aosp
./scripts/logs-tail.sh build-pi4
./scripts/logs-tail.sh build-pi5
```

`logs-tail.sh` just `tail -F`s the appropriate `latest-*.log`
symlink, so if a new invocation starts in the middle of a tail,
the symlink rotates and the tail follows to the new file.

Ctrl-C stops the tail — **it does not touch the build**.

## Filtering a noisy build log

`make` output is verbose. To watch only progress / errors:

```bash
tail -F logs/latest-build-pi4.log | grep -E --line-buffered \
  '\[[ ]*[0-9]+%\]|^FAILED:|error:|warning:'
```

For `repo sync`, the interesting lines look like `Fetching project`
and `error: ...`:

```bash
tail -F logs/latest-sync-aosp.log | grep -E --line-buffered \
  'Fetching|Updating files|error:|Server does not|done'
```

## Listing all logs

```bash
./scripts/logs-list.sh
```

Output (example):

```
FILE                              SIZE  MTIME                     STATUS
-----------------------------------------------------------------------------
build-pi5-20260410-023015.log      45M  2026-04-10T04:38:12       done (exit=0)
build-pi4-20260410-001100.log      43M  2026-04-10T02:12:44       done (exit=0)
sync-aosp-20260409-160500.log     812M  2026-04-09T19:42:11       done (exit=0)
create-vm-20260409-143652.log     3.2K  2026-04-09T14:38:47       done (exit=0)
```

A `running / incomplete` status means either (a) the script is
still executing, or (b) it crashed without unwinding the EXIT trap
(rare — kill -9 or power loss).

## Log retention

Logs live on the same APFS volume as the VM, which has ~1.4 TiB
free. They are **never auto-deleted**. To trim them manually:

```bash
# delete anything older than 30 days
find logs -type f -name '*.log' -mtime +30 -delete
```

Or just wipe everything non-current:

```bash
# keep only the most recent log for each tag
find logs -type f -name '*.log' \
  | sort \
  | awk -F- '{ key=$1"-"$2; if (seen[key]++) print }' \
  | xargs -r rm
```

## Lima's own logs (boot / QEMU)

In addition to our logs, Lima itself writes to
`$LIMA_HOME/aaos-builder/`:

| File | What it captures |
|---|---|
| `ha.stdout.log`     | hostagent stdout (time sync, port forwards, probes) |
| `ha.stderr.log`     | hostagent stderr |
| `serial*.log`       | Guest kernel / systemd serial console — this is the place to look if the VM won't finish booting |
| `cidata.iso`        | cloud-init seed image (config, not a log) |

Tail the guest serial console if cloud-init / apt are misbehaving:

```bash
tail -F lima/aaos-builder/serial0.log
```

## In-VM logs (ccache, repo, etc.)

Inside the VM, ccache and repo also keep their own state:

| Path | Purpose |
|---|---|
| `~/aosp/out/.ccache/log`                 | ccache verbose log (off by default) |
| `~/aosp/.repo/manifests.git`             | repo init state |
| `~/aosp/out/build-*.log`                 | AOSP's own build log per target |
| `~/aosp/out/verbose.log.gz`              | verbose soong output (on failures) |

To dig into a failed AOSP build after the fact:

```bash
./scripts/vm-shell.sh -- bash -c '
  cd ~/aosp
  ls -lt out/build-*.log | head
  zless out/verbose.log.gz 2>/dev/null || less out/verbose.log
'
```

## Running a script in the background

If you want to start a long build and free the terminal completely:

```bash
nohup ./scripts/03-build.sh pi5 >/dev/null 2>&1 &
disown
./scripts/logs-tail.sh build-pi5   # watch from wherever, whenever
```

The log file is the source of truth — the script's own terminal is
redundant.
