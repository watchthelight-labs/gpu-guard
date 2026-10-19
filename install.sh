#!/bin/bash
# <wtl> project: gpu-guard | file: install.sh | author: watchthelight </wtl>
# Install the GPU boot guard: sudo ./install.sh (from this folder, as the user who will confirm the boots).
# Writes /usr/local/etc/gpu-guard.conf with GUARD_USER set to that user if no config is there yet.
# Undo:
#   sudo launchctl bootout system/org.watchthelight.gpu-guard
#   sudo rm /Library/LaunchDaemons/org.watchthelight.gpu-guard.plist /usr/local/bin/gpu-guard /usr/local/bin/gpu-guard-ok
#   sudo rm /usr/local/etc/gpu-guard.conf
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
CONF=/usr/local/etc/gpu-guard.conf
mkdir -p /usr/local/bin /usr/local/etc /Users/Shared/gpu-guard
if [ ! -f "$CONF" ]; then
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || { echo "run with sudo from the user account that confirms the boots, or write $CONF first (see gpu-guard.conf.example)"; exit 1; }
  sed "s/^GUARD_USER=.*/GUARD_USER=$SUDO_USER/" gpu-guard.conf.example > "$CONF"
  chown root:wheel "$CONF"; chmod 644 "$CONF"
  echo "wrote $CONF (GUARD_USER=$SUDO_USER)"
fi
install -m 755 -o root -g wheel guard.sh /usr/local/bin/gpu-guard
install -m 755 -o root -g wheel gpu-guard-ok /usr/local/bin/gpu-guard-ok
install -m 644 -o root -g wheel org.watchthelight.gpu-guard.plist /Library/LaunchDaemons/org.watchthelight.gpu-guard.plist
launchctl bootout system/org.watchthelight.gpu-guard 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/org.watchthelight.gpu-guard.plist
echo "installed /usr/local/bin/gpu-guard, gpu-guard-ok and the LaunchDaemon (log: /Users/Shared/gpu-guard/gpu-guard.log)"
