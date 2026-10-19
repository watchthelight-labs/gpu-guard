#!/bin/bash
# <wtl> project: gpu-guard | file: guard.sh | author: watchthelight </wtl>
# Boot-time GPU driver guard (LaunchDaemon org.watchthelight.gpu-guard, root). stage.sh records a staged driver boot in
# pending.json before the reboot. On that boot this script waits for the login, then gives the user a window (default
# 180 s) to confirm that the screen works: the Good button of the dialog it shows, or `gpu-guard-ok` (which a helper,
# a second machine over ssh or an agent runs when the user says Good). No confirmation in time, or the driver kexts not
# loaded at all, means the panel is probably frozen: the guard captures the driver's counters and log, installs the
# recovery package (the last known good driver) and restarts. One automatic restart at most; a rollback boot is checked
# and recorded, never rolled back again. Only the person looking at the screen confirms: a screenshot can look fine
# while the panel is frozen.
#   GPU_GUARD_DRY=1 guard.sh       no install, no reboot (the dry run) on a temporary copy of pending.json, so the real
#                                  attempt stays unjudged; GPU_GUARD_PENDING=<file> another pending file
# Settings: /usr/local/etc/gpu-guard.conf (GPU_GUARD_CONF=<file> for another one), see gpu-guard.conf.example.
set -u
CONF=${GPU_GUARD_CONF:-/usr/local/etc/gpu-guard.conf}
[ -f "$CONF" ] && . "$CONF"
USER_NAME=${GUARD_USER:-}
[ -n "$USER_NAME" ] || { echo "gpu-guard: GUARD_USER is not set in $CONF" >&2; exit 1; }
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}'); [ -n "$USER_HOME" ] || USER_HOME=/Users/$USER_NAME
S=${GPU_GUARD_STATE:-${GUARD_STATE_DIR:-$USER_HOME/.cache/gpu-guard}}
P=${GPU_GUARD_PENDING:-$S/pending.json}
OK=$S/ok
LOGDIR=${GUARD_LOG_DIR:-/Users/Shared/gpu-guard}
LOG=$LOGDIR/gpu-guard.log
DRY=${GPU_GUARD_DRY:-0}
# what the driver looks like; the defaults are NullMoth's NVIDIA driver (NVMTLDriver plugin, NVRM/NVRMFB/NVAccel kexts)
PLUGIN_REL=${GUARD_PLUGIN:-Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver}
KEXT_LOADED=${GUARD_KEXT:-nullmoth.NVRMFB}
BINARIES=${GUARD_BINARIES:-/$PLUGIN_REL /Library/Extensions/NVRM.kext/Contents/MacOS/NVRM /Library/Extensions/NVRMFB.kext/Contents/MacOS/NVRMFB /Library/Extensions/NVAccel.kext/Contents/MacOS/NVAccel}
KEXT_GREP=${GUARD_KEXT_GREP:-nullmoth|watchthelight}
SYSCTL_GREP=${GUARD_SYSCTL_GREP:-nvrmfb|nvaccel|nvgfx}
DMESG_GREP=${GUARD_DMESG_GREP:-nvrm|nvaccel|cursor|nullmoth}
IOREG_CLASS=${GUARD_IOREG_CLASS:-NVRMNVDAFramebuffer}
IOREG_KEYS=${GUARD_IOREG_KEYS:-NVRMTrace|NVRMTraceCount|nvrm-flip|driver-version|nullmoth-nv-ok}
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
mkdir -p "$S" "$LOGDIR"; touch "$LOG"; chmod 644 "$LOG" 2>/dev/null
[ "$(id -u)" = 0 ] && chown "$USER_NAME":staff "$S" 2>/dev/null
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
[ -f "$P" ] || { log "no pending attempt"; exit 0; }
# a dry run must never write started_boot or a result into the real pending file: a later staged boot would then be
# taken for an earlier one and go unguarded
if [ "$DRY" = 1 ] && [ -z "${GPU_GUARD_PENDING:-}" ]; then T=$(mktemp -t gpu-guard-dry); cp "$P" "$T"; P=$T; log "DRY: working on a copy ($P)"; fi
BOOT=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
PY=/usr/bin/python3
field() { $PY -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(v if not isinstance(v,bool) else int(v))' "$P" "$1"; }
setfield() { $PY - "$P" "$1" "$2" <<'PYEOF'
import json, sys
p, k, v = sys.argv[1:4]
d = json.load(open(p))
try: v = json.loads(v)
except Exception: pass
d[k] = v
json.dump(d, open(p, "w"), indent=1)
PYEOF
}
ATTEMPT=$(field attempt); LABEL=$(field label); RECOVERY=$(field recovery)
TIMEOUT=$(field timeout); [ -n "$TIMEOUT" ] || TIMEOUT=180
REBOOTS=$(field auto_reboots); [ -n "$REBOOTS" ] || REBOOTS=0
STARTED=$(field started_boot); RESULT=$(field result); STAGED_BOOT=$(field staged_boot)

capture() {
  local d=$S/$ATTEMPT-$1
  mkdir -p "$d"
  kextstat 2>/dev/null | grep -E "$KEXT_GREP" > "$d/kextstat.txt"
  # shellcheck disable=SC2086  # GUARD_BINARIES is a space-separated list
  shasum -a 256 $BINARIES 2>/dev/null | cut -c1-12,65- > "$d/driver-sums.txt"
  sysctl debug 2>/dev/null | grep -iE "$SYSCTL_GREP" > "$d/sysctl.txt"
  dmesg 2>/dev/null | grep -iE "$DMESG_GREP" | tail -400 > "$d/dmesg-driver.txt"
  ioreg -r -c "$IOREG_CLASS" -l -w0 2>/dev/null | grep -E "\"($IOREG_KEYS)\"" | cut -c1-4000 > "$d/ioreg-fb.txt"
  pgrep -x WindowServer >/dev/null && echo "WindowServer running (pid $(pgrep -x WindowServer | head -1))" > "$d/windowserver.txt" || echo "WindowServer NOT running" > "$d/windowserver.txt"
  find /Library/Logs/DiagnosticReports "$USER_HOME/Library/Logs/DiagnosticReports" -name '*.ips' -newermt "@$BOOT" 2>/dev/null > "$d/crashes.txt"
  # a screen capture through the compositor: on one test boot it was fine while the panel was frozen, so a good capture
  # here with no confirmation points at the flip path, a bad one at the driver as a whole
  launchctl asuser "$(id -u "$USER_NAME")" sudo -u "$USER_NAME" screencapture -x "$d/screen.png" 2>/dev/null
  chown -R "$USER_NAME":staff "$d" 2>/dev/null
  log "captured $1 -> $d"
}
kexts_loaded() { kextstat 2>/dev/null | grep -q "$KEXT_LOADED"; }
plugin_sum() { shasum -a 256 "/$PLUGIN_REL" 2>/dev/null | cut -c1-12; }
console_user() { stat -f %Su /dev/console 2>/dev/null; }
wait_login() {
  # the window starts when the user is logged in and the compositor runs; a boot that never shows the login screen is
  # the driver installer's own fallback's job, so this waits without a cap
  while [ "$(console_user)" != "$USER_NAME" ] || ! pgrep -x WindowServer >/dev/null; do sleep 5; done
  sleep 10
}
ask_dialog() {
  # the dialog in the user's session: its Good button is one of the two confirmations (gpu-guard-ok is the other)
  local uid; uid=$(id -u "$USER_NAME")
  ( ans=$(launchctl asuser "$uid" sudo -u "$USER_NAME" osascript -e "display dialog \"Driver boot $ATTEMPT ($LABEL).\n\nIf you can read this and the screen updates, click Good (or run gpu-guard-ok) within $TIMEOUT seconds. Otherwise the last good driver is put back and the Mac restarts by itself.\" buttons {\"Roll back now\", \"Good\"} default button \"Good\" with title \"GPU guard $ATTEMPT\" with icon caution giving up after $TIMEOUT" 2>/dev/null)
    case "$ans" in
      *"button returned:Good"*"gave up:false"*) echo "dialog $BOOT" > "$OK"; chown "$USER_NAME":staff "$OK" 2>/dev/null ;;
      *"Roll back now"*) echo "rollback" > "$S/rollback-now" ;;
    esac ) &
  DIALOG_PID=$!
}
confirmed() { { [ -f "$OK" ] && grep -q "$BOOT" "$OK"; } || { [ -f "$OK-user" ] && grep -q "$BOOT" "$OK-user"; }; }
rollback() {
  local why=$1
  capture "rollback"
  if [ ! -f "$RECOVERY/install.sh" ]; then log "ROLLBACK IMPOSSIBLE: no $RECOVERY/install.sh"; setfield result '"stuck"'; setfield reason "\"no recovery package: $why\""; return 1; fi
  if [ "$DRY" = 1 ]; then log "DRY: would install $RECOVERY and restart ($why)"; setfield result '"rolled-back"'; setfield reason "\"$why\""; return 0; fi
  log "rollback ($why): installing $RECOVERY"
  # the rollback boot checks the plugin against this sum, so a failed install is not taken for a recovered driver
  setfield recovery_expected "\"$(shasum -a 256 "$RECOVERY/$PLUGIN_REL" 2>/dev/null | cut -c1-12)\""
  if (cd "$RECOVERY" && bash ./install.sh) > "$S/$ATTEMPT-rollback/install.log" 2>&1; then
    log "recovery package installed (plugin now $(plugin_sum))"; setfield recovery_install '"ok"'
  else
    log "RECOVERY INSTALL FAILED (see $S/$ATTEMPT-rollback/install.log); restarting anyway, the installer's own fallback may apply"
    setfield recovery_install '"failed"'
  fi
  setfield result '"rolled-back"'; setfield reason "\"$why\""; setfield auto_reboots "$((REBOOTS + 1))"
  sync; sleep 2
  shutdown -r now "gpu-guard rollback $ATTEMPT: $why"
}

log "guard start: attempt=$ATTEMPT label='$LABEL' recovery=$RECOVERY timeout=${TIMEOUT}s boot=$BOOT started_boot=${STARTED:-none} result=${RESULT:-none} auto_reboots=$REBOOTS dry=$DRY"
case "$RESULT" in
  pass|stuck|pass-after-rollback|failed-after-rollback) log "attempt already finished ($RESULT); nothing to do"; exit 0 ;;
esac
if [ "$RESULT" = "rolled-back" ]; then
  log "this is the rollback boot; checking the recovery driver"
  wait_login
  want=$(field recovery_expected); have=$(plugin_sum)
  if [ -n "$want" ] && [ "$have" != "$want" ]; then
    setfield result '"failed-after-rollback"'; setfield reason "\"recovery plugin not in place (have $have, want $want; install $(field recovery_install))\""
    log "ROLLBACK BOOT STILL ON THE STAGED PLUGIN ($have, want $want): left for a person"; exit 1
  fi
  if kexts_loaded; then setfield result '"pass-after-rollback"'; setfield recovery_plugin "\"$have\""; log "rollback boot ok: kexts loaded, plugin $have"; exit 0; fi
  setfield result '"failed-after-rollback"'; log "ROLLBACK BOOT WITHOUT THE DRIVER KEXTS: left for a person"; exit 1
fi
# staged in this very boot (install.sh bootstraps the daemon, which runs at load): the staged driver has not booted yet
if [ -z "$STARTED" ] && [ -n "$STAGED_BOOT" ] && [ "$STAGED_BOOT" = "$BOOT" ] && [ "$DRY" != 1 ]; then
  log "attempt $ATTEMPT was staged in this boot; waiting for the reboot"; exit 0
fi
# a started marker from an earlier boot with no result: that boot never got a decision (a panic the user power-cycled,
# or a restart before the window closed); the staged driver is not trusted
if [ -n "$STARTED" ] && [ "$STARTED" != "$BOOT" ]; then
  if [ "$REBOOTS" -ge 1 ]; then setfield result '"stuck"'; setfield reason '"second boot without a confirmation"'; log "STUCK: no further restart"; exit 1; fi
  wait_login; rollback "earlier boot $STARTED ended without a confirmation"; exit $?
fi
setfield started_boot "$BOOT"; rm -f "$OK" "$OK-user" "$S/rollback-now"
wait_login
log "logged in; window of ${TIMEOUT}s for the user's confirmation starts now"
capture "login"
if ! kexts_loaded; then log "driver kexts not loaded"; rollback "$KEXT_LOADED not loaded after login"; exit $?; fi
ask_dialog
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  confirmed && break
  [ -f "$S/rollback-now" ] && { log "rollback asked for in the dialog"; rollback "rolled back on request"; exit $?; }
  sleep 2
done
if confirmed; then
  how=$(cat "$OK" 2>/dev/null || cat "$OK-user" 2>/dev/null)
  setfield result '"pass"'; setfield reason "\"confirmed by the user ($how)\""; log "PASS $ATTEMPT: confirmed ($how)"
  kill "${DIALOG_PID:-0}" 2>/dev/null; pkill -f "GPU guard $ATTEMPT" 2>/dev/null; exit 0
fi
log "NO CONFIRMATION for $ATTEMPT within ${TIMEOUT}s"
if [ "$REBOOTS" -ge 1 ]; then setfield result '"stuck"'; setfield reason '"no confirmation after a rollback"'; log "STUCK"; exit 1; fi
rollback "no confirmation within ${TIMEOUT}s of login"
