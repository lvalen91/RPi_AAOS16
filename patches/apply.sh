#!/usr/bin/env bash
# patches/apply.sh <aosp-tree> — apply the Pi 4 platform patches to a synced AOSP tree.
#
# Idempotent: a patch already present is skipped, not re-applied.
#
# These are AOSP-project patches, one directory per repo project. They are kept
# as files rather than as branches in the tree because `repo sync --force-sync`
# detaches local branches, and because a 300 GB repo checkout is not a
# distribution mechanism — this is what lets someone else rebuild the image.
#
# Applied with `git am`, so each lands as a real commit. That gives provenance in
# the tree and makes "is it already applied?" a log lookup rather than a guess.
# The guess matters: two patches that append to the same file share end-of-file
# context, so `git apply --reverse --check` cannot tell "already applied" from
# "conflicts" once both are on. Asking the log is unambiguous.
#
# The kernel is NOT patched here — it is a separate out-of-tree build. See
# build_kernel_rpi4.sh, which applies patches/kernel_brcm_rpi/ itself.
set -euo pipefail

AOSP="${1:-}"
[ -n "$AOSP" ] || { echo "usage: $0 <aosp-tree>" >&2; exit 1; }
[ -d "$AOSP/.repo" ] || { echo "not an AOSP tree: $AOSP" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# patch directory -> project path in the AOSP tree
PROJECTS="
device_brcm_rpi4:device/brcm/rpi4
hardware_interfaces:hardware/interfaces
external_ffmpeg_codec2:external/ffmpeg_codec2
"

rc=0
for entry in $PROJECTS; do
  dir="${entry%%:*}"
  proj="${entry##*:}"
  [ -d "$SCRIPT_DIR/$dir" ] || continue
  if [ ! -d "$AOSP/$proj" ]; then
    echo "SKIP  $proj (not in tree)"
    continue
  fi

  for p in "$SCRIPT_DIR/$dir"/*.patch; do
    [ -e "$p" ] || continue
    name="$(basename "$p")"

    # Subject, minus the "[PATCH] " prefix — this is what git am records.
    # git format-patch folds long subjects over continuation lines (RFC 2822:
    # a continuation starts with whitespace), so they have to be unfolded or the
    # comparison silently truncates and never matches.
    subject="$(awk '
      /^Subject:/ {
        s = substr($0, 10)
        while ((getline line) > 0 && line ~ /^[ \t]/) {
          sub(/^[ \t]+/, " ", line)
          s = s line
        }
        sub(/^\[PATCH[^]]*\] */, "", s)
        print s
        exit
      }' "$p")"
    if [ -z "$subject" ]; then
      echo "FAIL  $proj: $name has no Subject line" >&2
      rc=1
      continue
    fi

    # Capture first, then match. Do NOT pipe `git log` into `grep -q`: grep exits
    # at the first match, git log takes SIGPIPE, and under `set -o pipefail` that
    # non-zero status makes the test read as "not applied" — so every patch gets
    # re-applied on every run, which is the exact opposite of the intent.
    log_subjects="$(git -C "$AOSP/$proj" log --format=%s)"
    if grep -Fxq "$subject" <<<"$log_subjects"; then
      echo "OK    $proj: $name (already applied)"
      continue
    fi

    if ! git -C "$AOSP/$proj" diff --quiet || ! git -C "$AOSP/$proj" diff --cached --quiet; then
      echo "FAIL  $proj: working tree is dirty, refusing to git am" >&2
      rc=1
      continue
    fi

    if git -C "$AOSP/$proj" am --3way --quiet "$p" 2>/dev/null; then
      echo "APPLY $proj: $name"
    else
      git -C "$AOSP/$proj" am --abort 2>/dev/null || true
      echo "FAIL  $proj: $name does not apply" >&2
      rc=1
    fi
  done
done

exit $rc
