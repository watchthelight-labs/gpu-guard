# gpu-guard

A boot-time safety net for testing GPU driver builds on macOS. You install a driver build you are not sure about, stage the boot, and restart. After you log in, the guard asks you whether the screen works. If you say Good within the window (180 s by default), the build is kept. If you don't, because the panel is frozen, black, or showing a picture that never changes, the guard saves what the driver was doing, installs the last driver that worked, and restarts the Mac by itself.

I wrote it while testing builds of a fork of NullMoth's NVIDIA Metal driver on a Hackintosh laptop. A bad build there often leaves macOS running fine underneath: you can ssh in, scripts keep going, a screenshot through the compositor even looks correct, but the panel itself shows nothing new. Anything automated that judges the boot from inside the machine gets fooled. So the guard only accepts the word of the person looking at the screen, and treats silence as a failure.

## The flow

1. Install the driver build under test with its own installer.
2. Stage the boot, naming a recovery package (a folder with an `install.sh` that puts the last good driver back):

   ```
   ./stage.sh test-07 "driver 2.3.6 rc1" ~/pkgs/driver-2.3.5
   ```

   `test-07` is any label you like; it names the capture folders. An optional fourth argument sets the window in seconds.
3. Restart.
4. Log in. The guard captures the driver state and shows a dialog: **Good** or **Roll back now**.
5. Confirm with the dialog's Good button, or run `gpu-guard-ok` from a terminal or over ssh. Result `pass`.
6. No confirmation within the window, the driver kexts not loaded at all, or Roll back now: the guard captures again, runs the recovery package's `install.sh` as root, and restarts. On the next boot it checks that the recovery driver is in place and loaded (`pass-after-rollback`), or leaves a `failed-after-rollback` for you.

The guard restarts the Mac at most once per attempt. A second failure is recorded as `stuck` and left alone.

## Installation

Needs admin rights (the guard is a root LaunchDaemon) and `/usr/bin/python3`, which comes with the Xcode Command Line Tools (`xcode-select --install`). Without them the guard can't read its state file.

```
git clone https://github.com/watchthelight-labs/gpu-guard
cd gpu-guard
sudo ./install.sh
```

Run it from the account that will confirm the boots. It installs:

| Path | What |
|---|---|
| `/usr/local/bin/gpu-guard` | the guard (`guard.sh`) |
| `/usr/local/bin/gpu-guard-ok` | the confirmation command |
| `/Library/LaunchDaemons/org.watchthelight.gpu-guard.plist` | runs the guard at every boot, as root |
| `/usr/local/etc/gpu-guard.conf` | settings, written from `gpu-guard.conf.example` with `GUARD_USER` set to you (only if it doesn't exist) |

The daemon also runs once right after install. With nothing staged it logs `no pending attempt` and exits. `stage.sh` stays in the clone; run it from there.

The guard also asks the driver itself whether the display came up: after login it reads an IORegistry property of
the driver's service (`HOLD_SERVICE`/`HOLD_PROP`/`HOLD_ARMED` in the config, NullMoth's NVRM `nvrm-boot-hold` =
"display armed" by default). A boot whose kexts loaded but whose display never armed runs on software rendering; the
guard rolls that back at once, and never counts such a rollback boot as good. Set `HOLD_PROP=""` to turn this off.

No password is stored anywhere. `install.sh` is run with `sudo` by you; `stage.sh` and `gpu-guard-ok` run as your normal user and don't need root.

## Configuration

`/usr/local/etc/gpu-guard.conf` is a shell file that all three scripts read. Only `GUARD_USER` is required. The rest have defaults that fit NullMoth's NVIDIA driver and forks of it:

| Setting | Default | Meaning |
|---|---|---|
| `GUARD_USER` | (set by install.sh) | the account that logs in and confirms |
| `GUARD_STATE_DIR` | `~/.cache/gpu-guard` | `pending.json`, the ok files and the captures |
| `GUARD_LOG_DIR` | `/Users/Shared/gpu-guard` | `gpu-guard.log` |
| `GUARD_REPO` | none | a git checkout that must be clean when you stage; its HEAD is recorded |
| `GUARD_PLUGIN` | `Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver` | the user-space driver, relative to `/` and to the recovery package root |
| `GUARD_KEXT` | `nullmoth.NVRMFB` | `kextstat` pattern that means the driver loaded |
| `GUARD_BINARIES` | the plugin plus the NVRM, NVRMFB and NVAccel kexts | files whose sha256 goes into each capture |
| `GUARD_KEXT_GREP`, `GUARD_SYSCTL_GREP`, `GUARD_DMESG_GREP`, `GUARD_IOREG_CLASS`, `GUARD_IOREG_KEYS` | NVIDIA driver names | filters for the captures |

For another driver, change `GUARD_PLUGIN`, `GUARD_KEXT` and the capture filters. The recovery package has to lay out the plugin at the same relative path, because the rollback boot compares its sha256 with the one installed.

Environment variables for testing: `GPU_GUARD_CONF` (another config file), `GPU_GUARD_STATE` (another state folder), `GPU_GUARD_PENDING` (another pending file), `GPU_GUARD_DRY=1` (dry run).

## Confirming

Two ways, both only count for the current boot:

- the **Good** button in the dialog (it gives up when the window closes, so a click after that does nothing);
- `gpu-guard-ok`, run as your user. It writes `ok-user` with the boot time and prints the result a few seconds later.

If you test with someone or something else at the keyboard, such as a second machine over ssh or a coding agent, they run `gpu-guard-ok` only when you tell them the screen works. They should never run it because a log or a screenshot looks fine. That's the whole point of the guard.

## What gets captured

Each attempt gets `<label>-login/` (right after login) and, on a rollback, `<label>-rollback/` in the state folder:

| File | Contents |
|---|---|
| `kextstat.txt` | loaded kexts matching `GUARD_KEXT_GREP` |
| `driver-sums.txt` | short sha256 of each file in `GUARD_BINARIES` |
| `sysctl.txt` | the driver's `debug.*` sysctls |
| `dmesg-driver.txt` | the last 400 matching kernel log lines |
| `ioreg-fb.txt` | the framebuffer's trace and flip properties |
| `windowserver.txt` | whether WindowServer is running |
| `crashes.txt` | crash reports newer than this boot |
| `screen.png` | a screen capture through the compositor (compare it with what you saw) |
| `install.log` | the recovery package's install output (rollback only) |

`pending.json` keeps the whole history of the attempt: `result`, `reason`, `started_boot`, `auto_reboots`, `recovery_expected`, `recovery_install`. It's plain JSON, so a login script can show it to you. The log is `/Users/Shared/gpu-guard/gpu-guard.log`.

## Dry run

Before trusting it, run it once without the install and the restart, with a short window:

```
cp ~/.cache/gpu-guard/pending.json /tmp/p.json      # after a stage.sh; set "timeout" to 20 in it
GPU_GUARD_DRY=1 GPU_GUARD_PENDING=/tmp/p.json sudo -E /usr/local/bin/gpu-guard
```

It shows the dialog. If you let it time out, it writes `rolled-back` into `/tmp/p.json` without installing or restarting. A dry run without `GPU_GUARD_PENDING` works on a temporary copy, so the real attempt stays unjudged.

## Uninstall

```
sudo launchctl bootout system/org.watchthelight.gpu-guard
sudo rm /Library/LaunchDaemons/org.watchthelight.gpu-guard.plist /usr/local/bin/gpu-guard /usr/local/bin/gpu-guard-ok
sudo rm /usr/local/etc/gpu-guard.conf
rm -rf ~/.cache/gpu-guard /Users/Shared/gpu-guard      # captures and log, if you don't want them
```

## Safety notes

- **The recovery package runs as root.** The guard runs `bash ./install.sh` from the folder recorded in `pending.json`, and that file lives in your user's state folder. Anyone who can write as your user can make the guard run a script as root on the next boot. Use it on a machine where your account is an admin anyway, and keep recovery packages somewhere only you write to.
- The config file is sourced by the root daemon. Keep it `root:wheel 644`, as `install.sh` leaves it.
- Test the recovery package by hand before relying on it. If its `install.sh` fails, the guard still restarts, and the rollback boot then reports `failed-after-rollback`.
- The guard waits for your login without a time limit. A boot that never reaches the login window (a panic or a hang before WindowServer) isn't caught on that boot. On the next boot after you power-cycle, the guard sees the unfinished attempt and rolls back after you log in.
- It only restarts once per attempt, so it can't loop.
- The dialog and the screen capture run in your session through `launchctl asuser`. Nothing is sent off the machine.

## Status

Used daily for driver test boots on a Lenovo Legion 5 15IAX10 Hackintosh (RTX 5070 Laptop, macOS 26.7.1 25G241) with a fork of NullMoth's NVIDIA Metal driver. So far it has passed the confirmed boots and rolled back one build with no confirmation on its own; the rollback boot came up on the last good driver (`pass-after-rollback`). Tested on that one machine only.

## How it works

The state machine, the boot-time checks and why each one is there: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). The Wi-Fi counterpart is [wifi-guard](https://github.com/watchthelight-labs/wifi-guard).

## Licence

ISC, see [LICENSE](LICENSE).
