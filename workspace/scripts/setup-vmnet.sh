#!/usr/bin/env bash
# setup-vmnet.sh — one-time privileged setup for Lima socket_vmnet networking.
#
# Lima refuses to use socket_vmnet if any component of the path to the
# binary is (a) a symlink, or (b) owned by a non-root user, or (c) in a
# user-writable parent. Homebrew on Intel fails all three: the installed
# binary lives at /usr/local/Cellar/socket_vmnet/<ver>/bin/socket_vmnet with
# a symlink at /usr/local/opt/socket_vmnet, and /usr/local itself is
# user-writable.
#
# The canonical Lima-approved layout is a standalone root-owned tree under
# /opt/socket_vmnet/bin. This script copies the brew binary there, owns
# the whole tree as root:wheel, generates the Lima sudoers entry, and
# installs it to /etc/sudoers.d/lima so `limactl start` never prompts for
# a password.
#
# Usage:
#     ./scripts/setup-vmnet.sh          # run directly from a real terminal
#                                       # (needs a tty for the sudo password)
#
# NOTE: the `!` chat-prefix path cannot supply a tty for sudo, so run this
# from a real Terminal window, not from the Claude prompt.
#
# Idempotent — safe to rerun after `brew upgrade socket_vmnet` to refresh
# the copied binary.

set -euo pipefail

BREW_PREFIX="${HOMEBREW_PREFIX:-/usr/local}"
BREW_BIN="$BREW_PREFIX/opt/socket_vmnet/bin/socket_vmnet"
TARGET_ROOT=/opt/socket_vmnet          # fresh root-owned tree Lima will accept
TARGET_BIN="$TARGET_ROOT/bin/socket_vmnet"
SUDOERS=/etc/sudoers.d/lima
VARRUN=/private/var/run/lima

if [ ! -e "$BREW_BIN" ]; then
  echo "FAIL: $BREW_BIN does not exist. Run:  brew install socket_vmnet" >&2
  exit 1
fi

echo "==> brew-installed socket_vmnet"
ls -l "$BREW_BIN"
echo "    -> will be copied to $TARGET_BIN (root-owned, non-symlink)"

echo
echo "==> Requesting sudo (one prompt)…"
sudo -v

# -----------------------------------------------------------------------
# 1. Install binary to /opt/socket_vmnet/bin as root, non-symlink
# -----------------------------------------------------------------------
echo
echo "==> Installing $TARGET_BIN"
sudo mkdir -p "$TARGET_ROOT/bin"
# Resolve the brew symlink before copying so we get the real file.
REAL_BIN=$(readlink -f "$BREW_BIN" 2>/dev/null || realpath "$BREW_BIN")
sudo install -o root -g wheel -m 0555 "$REAL_BIN" "$TARGET_BIN"
# Own the whole subtree root:wheel and strip group/world write.
sudo chown -R root:wheel "$TARGET_ROOT"
sudo chmod -R go-w      "$TARGET_ROOT"

# Paranoia: ensure no component of the path is a symlink
for p in /opt /opt/socket_vmnet /opt/socket_vmnet/bin /opt/socket_vmnet/bin/socket_vmnet; do
  if [ -L "$p" ]; then
    echo "FAIL: $p is still a symlink — aborting."
    exit 1
  fi
done

echo "    verified: $TARGET_BIN is root-owned and not a symlink"
ls -l "$TARGET_BIN"

# -----------------------------------------------------------------------
# 2. Create Lima's varRun (root-owned, non-user-writable)
# -----------------------------------------------------------------------
echo
echo "==> Ensuring $VARRUN exists root-owned"
sudo mkdir -p "$VARRUN"
sudo chown root:wheel "$VARRUN"
sudo chmod 0755 "$VARRUN"

# -----------------------------------------------------------------------
# 3. Generate the Lima sudoers snippet and install it
# -----------------------------------------------------------------------
# LIMA_HOME must match what the host scripts use so the generated sudoers
# references the correct socket paths.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Source env.sh so this matches the real LIMA_HOME rather than re-deriving
# the old $AAOS_ROOT/lima path (the instance moved out of the project dir
# on 2026-08-14).
# shellcheck source=env.sh
[ -n "${LIMA_HOME:-}" ] || source "$SCRIPT_DIR/env.sh"
echo
echo "==> Generating sudoers snippet with LIMA_HOME=$LIMA_HOME"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
limactl sudoers > "$TMP"
echo "    wrote $(wc -l < "$TMP" | tr -d ' ') lines"

echo
echo "==> Installing $SUDOERS"
sudo install -o root -g wheel -m 0440 "$TMP" "$SUDOERS"

# Sanity-check the syntax — refuse to leave a broken sudoers behind.
if ! sudo visudo -cf "$SUDOERS" >/dev/null; then
  echo "FAIL: generated sudoers failed visudo check; removing."
  sudo rm -f "$SUDOERS"
  exit 1
fi

echo
echo "==> Done."
echo "    socket_vmnet: $TARGET_BIN (root:wheel, 0555, not a symlink)"
echo "    sudoers:      $SUDOERS (root:wheel, 0440)"
echo "    varRun:       $VARRUN"
echo
echo "Next step: from Claude, I'll stop the VM, add the networks: block to"
echo "the existing instance, restart it, and kick off the sync at -j32."
echo "Your repo data so far (~61 GB in the VM's ~/aosp) is preserved."
