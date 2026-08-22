#!/usr/bin/env bash
# scripts/env.sh — sourced by every host-side script.
#
# Pins LIMA_HOME so the VM disk and all instance state live on the external
# volume instead of ~/.lima. Every other script sources this first; do not
# run it directly.
#
# 2026-08-14: LIMA_HOME moved from "$AAOS_ROOT/lima" to the shared
# /Volumes/stuff/virtual-machines/lima so this VM sits alongside the other
# Lima instances under one lima home. The project layout (out/, scripts/,
# overlays/, docs/) still lives here at $AAOS_ROOT and the VM's mounts still
# point at it -- only the instance directory moved.

set -eu

# Resolve the script path across bash (BASH_SOURCE) and zsh (%N) so
# env.sh can be sourced interactively for debugging from either shell.
if [ -n "${BASH_SOURCE+set}" ]; then
  _aaos_env_src="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION-}" ]; then
  # shellcheck disable=SC2296
  _aaos_env_src="${(%):-%N}"
else
  _aaos_env_src="$0"
fi
AAOS_ROOT="$(cd "$(dirname "$_aaos_env_src")/.." && pwd)"
unset _aaos_env_src
export AAOS_ROOT

# Shared lima home on the external volume. Override by exporting
# AAOS_LIMA_HOME before sourcing, e.g. to test against a scratch instance.
export LIMA_HOME="${AAOS_LIMA_HOME:-/Volumes/stuff/virtual-machines/lima}"
export VM_NAME="aaos-builder"
export AAOS_TEMPLATE="$AAOS_ROOT/templates/aaos-builder.yaml"
export AAOS_OUT="$AAOS_ROOT/out"
export AAOS_OVERLAYS="$AAOS_ROOT/overlays"
export AAOS_LOGS="$AAOS_ROOT/logs"

mkdir -p "$LIMA_HOME" "$AAOS_OUT" "$AAOS_OVERLAYS" "$AAOS_LOGS"

# Colorised output helpers (disabled when piped through tee so the log
# file doesn't get littered with ANSI escapes)
if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[1;33m'
  C_CYN='\033[0;36m'; C_OFF='\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_OFF=''
fi
export C_RED C_GRN C_YLW C_CYN C_OFF

say()  { printf "${C_CYN}==>${C_OFF} %s\n" "$*"; }
ok()   { printf "${C_GRN}OK${C_OFF}  %s\n" "$*"; }
warn() { printf "${C_YLW}WARN${C_OFF} %s\n" "$*"; }
die()  { printf "${C_RED}FAIL${C_OFF} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
# VM script transport
# ---------------------------------------------------------------------
# We do NOT execute scripts directly from /mnt/scripts (the 9p mount)
# because 9p has cache-coherency issues — rapid edits on the host can
# be stale on the guest for an unpredictable window. Instead, every
# host wrapper calls vm_push_scripts first, which tars scripts/vm/ up
# on the host and untars it into /tmp/aaos-scripts/ on the guest.
# Running from there guarantees the script content matches the host
# file byte-for-byte.
#
# /mnt/scripts remains mounted (see templates/aaos-builder.yaml) but
# is effectively historical. /mnt/out and /mnt/overlays are still used
# for their data-sharing purpose.

export VM_SCRIPTS_HOST="$AAOS_ROOT/scripts/vm"
export VM_SCRIPTS_GUEST="/tmp/aaos-scripts"

vm_push_scripts() {
  [ -d "$VM_SCRIPTS_HOST" ] || die "host scripts dir missing: $VM_SCRIPTS_HOST"
  (cd "$VM_SCRIPTS_HOST" && tar -cf - .) | \
    limactl shell "$VM_NAME" bash -c "mkdir -p $VM_SCRIPTS_GUEST && cd $VM_SCRIPTS_GUEST && tar -xf - && chmod +x *.sh"
}

# vm_run <script-name> [args...]  — execute a script from $VM_SCRIPTS_GUEST
vm_run() {
  local script="$1"; shift
  limactl shell "$VM_NAME" bash "$VM_SCRIPTS_GUEST/$script" "$@"
}

# ---------------------------------------------------------------------
# start_log <tag>
#   Redirects the REST of the current script's stdout and stderr to a
#   fresh log file under $AAOS_LOGS/<tag>-<YYYYmmdd-HHMMSS>.log while
#   still showing output on the terminal. A stable symlink
#   $AAOS_LOGS/latest-<tag>.log always points at the newest run.
#
# Usage (from any numbered script, immediately after sourcing env.sh):
#
#     start_log sync-aosp
#     …rest of the script…
#
# Monitor live from another terminal with:
#
#     ./scripts/logs-tail.sh            # tail the newest log of any tag
#     ./scripts/logs-tail.sh sync-aosp  # or a specific tag
# ---------------------------------------------------------------------
start_log() {
  local tag="$1"
  local ts log
  ts="$(date +%Y%m%d-%H%M%S)"
  log="$AAOS_LOGS/${tag}-${ts}.log"
  ln -sf "${tag}-${ts}.log" "$AAOS_LOGS/latest-${tag}.log"
  ln -sf "${tag}-${ts}.log" "$AAOS_LOGS/latest.log"

  # Tee everything that follows to the log file AND the terminal.
  # Using a process substitution keeps the original tty attached.
  exec > >(tee -a "$log") 2>&1

  printf '==== %s: start  %s  (pid=%d) ====\n' \
    "$tag" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$"
  printf 'log: %s\n' "$log"

  # Print exit marker regardless of success/failure.
  # shellcheck disable=SC2064
  trap '_rc=$?; printf "==== '"$tag"': end    %s  exit=%d ====\n" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$_rc"; exit $_rc' EXIT

  # Remind the user how to tail (printed to the terminal *and* the log,
  # so if they open the log file it also says how to follow it live).
  say "live tail: tail -F $AAOS_LOGS/latest-${tag}.log"
}
