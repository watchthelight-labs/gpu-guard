#!/bin/bash
# <wtl> project: gpu-guard | file: stage.sh | author: watchthelight </wtl>
# Record a staged GPU driver boot for the guard (guard.sh). The driver itself is installed separately with its package's
# installer; this only tells the guard which boot to watch and what to put back. Run as the user named in GUARD_USER:
#   ./stage.sh test-07 "driver 2.3.6" ~/pkgs/driver-2.3.5 [timeout seconds, default 180]
# The first argument is a free-form label for the attempt (it names the capture folders). Then restart the Mac. After
# the boot, confirm within the window (the dialog's Good button or `gpu-guard-ok`); without that the guard installs the
# recovery package and restarts. With GUARD_REPO set in the config, staging refuses while that git repo has uncommitted
# changes and records its HEAD.
set -euo pipefail
CONF=${GPU_GUARD_CONF:-/usr/local/etc/gpu-guard.conf}
[ -f "$CONF" ] && . "$CONF"
ID=${1:?attempt label}; LABEL=${2:?description}; RECOVERY=${3:?recovery package dir with install.sh}; TIMEOUT=${4:-180}
RECOVERY=$(cd "$RECOVERY" && pwd)
[ -f "$RECOVERY/install.sh" ] || { echo "FAIL: no install.sh in $RECOVERY"; exit 1; }
REPO=${GUARD_REPO:-}; S=${GPU_GUARD_STATE:-${GUARD_STATE_DIR:-$HOME/.cache/gpu-guard}}; mkdir -p "$S"
PLUGIN=/${GUARD_PLUGIN:-Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver}
if [ -n "$REPO" ] && [ -n "$(git -C "$REPO" status --porcelain | grep -v '^??')" ]; then echo "REFUSED: uncommitted changes in $REPO"; exit 2; fi
[ -f /Library/LaunchDaemons/org.watchthelight.gpu-guard.plist ] || { echo "FAIL: the gpu-guard LaunchDaemon is not installed (sudo ./install.sh)"; exit 1; }
rm -f "$S/ok" "$S/ok-user" "$S/rollback-now"
/usr/bin/python3 - "$ID" "$LABEL" "$RECOVERY" "$TIMEOUT" "$S/pending.json" "$REPO" "$PLUGIN" <<'PY'
import json, sys, time, subprocess
aid, label, rec, timeout, path, repo, plugin_path = sys.argv[1:8]
head = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() if repo else ""
boot = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True).stdout.split("sec = ")[1].split(",")[0]
plugin = subprocess.run(["shasum", "-a", "256", plugin_path], capture_output=True, text=True).stdout[:12]
json.dump({"attempt": aid, "label": label, "recovery": rec, "timeout": int(timeout), "auto_reboots": 0, "repo_head": head,
           "staged_plugin": plugin, "staged_boot": int(boot), "staged_at": time.strftime("%Y-%m-%d %H:%M:%S %Z")}, open(path, "w"), indent=1)
print(f"pending {aid} ({label}) recorded in {path}: recovery {rec}, window {timeout}s, installed plugin {plugin}")
PY
echo "staged $ID: restart the Mac; after the boot confirm within ${TIMEOUT}s of login (Good in the dialog, or gpu-guard-ok)"
