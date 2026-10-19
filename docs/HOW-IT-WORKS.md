# How gpu-guard works

Three scripts share one JSON file, `pending.json` in the state folder.

## stage.sh

Runs as the user, before the restart. It refuses if the LaunchDaemon isn't installed or, with `GUARD_REPO` set, if that repo has uncommitted changes. Then it deletes any old `ok`, `ok-user` and `rollback-now` files and writes:

```json
{
 "attempt": "test-07",
 "label": "driver 2.3.6 rc1",
 "recovery": "/Users/you/pkgs/driver-2.3.5",
 "timeout": 180,
 "auto_reboots": 0,
 "repo_head": "",
 "staged_plugin": "1a2b3c4d5e6f",
 "staged_boot": 1792390000,
 "staged_at": "2026-10-19 10:00:00 CEST"
}
```

`staged_boot` is `kern.boottime` of the boot you staged in. The guard uses it to tell that boot apart from the one being tested.

## guard.sh

Runs as root at every boot (`RunAtLoad`), and once when `install.sh` loads it. With no `pending.json` it exits. Otherwise it reads the attempt and decides by `result`:

| State | What the guard does |
|---|---|
| `result` is `pass`, `stuck`, `pass-after-rollback` or `failed-after-rollback` | nothing, the attempt is finished |
| `result` is `rolled-back` | this is the rollback boot: wait for login, compare the plugin's sha256 with `recovery_expected`, check the driver kext is loaded. Record `pass-after-rollback` or `failed-after-rollback`. Never restarts |
| no `started_boot`, and `staged_boot` is this boot | staged in this very boot (the daemon ran at install or at load): wait for the restart |
| `started_boot` is an earlier boot and no result | that boot never got a decision (a panic you power-cycled, or a restart inside the window). The staged driver is not trusted: wait for login and roll back, or record `stuck` if it already restarted once |
| otherwise | the boot under test, below |

For the boot under test:

1. Write `started_boot`, remove old confirmations.
2. Wait until `GUARD_USER` owns the console and WindowServer runs, then 10 more seconds. There is no cap on this wait, on purpose: the window must start when you can actually see the screen.
3. Capture into `<attempt>-login/`.
4. If the driver kext (`GUARD_KEXT`) isn't loaded, roll back at once.
5. Show the dialog in your session (`launchctl asuser` + `osascript`, `giving up after` the window). Good writes `ok` with the boot time; Roll back now writes `rollback-now`.
6. Poll every 2 s until the deadline for `ok` or `ok-user` holding this boot's time, or `rollback-now`.
7. Confirmed: `result: pass`, close the dialog. Not confirmed: roll back, unless the attempt already restarted once (`stuck`).

The confirmation files carry the boot time so that a stale `ok` left from an earlier boot can never pass a new one.

### Rollback

1. Capture into `<attempt>-rollback/`.
2. No `install.sh` in the recovery folder: `stuck`, no restart.
3. Record `recovery_expected`, the sha256 of the recovery package's own copy of the plugin. The rollback boot checks against it, so an install that silently failed isn't taken for a recovered driver.
4. Run `bash ./install.sh` in the recovery folder, output to `install.log`. Record `recovery_install` as `ok` or `failed`. A failed install still restarts: the driver installer may have its own fallback, and the rollback boot reports what it finds.
5. `result: rolled-back`, `auto_reboots + 1`, `shutdown -r now`.

In a dry run (`GPU_GUARD_DRY=1`) step 4 and the restart are skipped and the result is written anyway, to a temporary copy of `pending.json` unless you named one with `GPU_GUARD_PENDING`. A dry run that wrote `started_boot` into the real file would make the next real boot look like an earlier unfinished one.

## gpu-guard-ok

Runs as the user. Writes `good <boot time> <date>` to `ok-user` (the guard owns `ok` as root, so the user's confirmation gets its own file), waits 3 s and prints the attempt's result.

## Why a person has to confirm

The failure this was built for is a panel that stops updating while everything else works: WindowServer runs, apps draw, `screencapture` returns a correct image, the driver's counters move. Only someone looking at the panel can tell. Any check from inside the machine would have passed those boots, so the guard doesn't try one, and a missing answer counts as a failure.
