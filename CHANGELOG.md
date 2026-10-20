# Changelog

## 0.1.1

- The guard reads the driver's own display verdict (an IORegistry property, NullMoth's `nvrm-boot-hold` by default):
  a staged boot whose display did not arm by login rolls back at once instead of waiting out the window, and a
  rollback boot without an armed display is `failed-after-rollback`, not a pass. Loaded kexts alone used to count as
  good, which missed a desktop running on software rendering. `HOLD_SERVICE`, `HOLD_PROP`, `HOLD_ARMED` in the config.
- The captures include the driver service's string properties (`driver-props.txt`).

## 0.1.0 (2026-10-19)

- First public release. `stage.sh` records a staged driver boot; the `org.watchthelight.gpu-guard` LaunchDaemon waits for login, captures the driver state, asks for a Good (dialog or `gpu-guard-ok`) and, without one, installs the recovery package and restarts once.
- Settings in `/usr/local/etc/gpu-guard.conf`; defaults fit NullMoth's NVIDIA Metal driver.
- Dry run mode (`GPU_GUARD_DRY=1`) that never touches the real attempt.
