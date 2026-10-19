# Changelog

## 0.1.0 (2026-10-19)

- First public release. `stage.sh` records a staged driver boot; the `org.watchthelight.gpu-guard` LaunchDaemon waits for login, captures the driver state, asks for a Good (dialog or `gpu-guard-ok`) and, without one, installs the recovery package and restarts once.
- Settings in `/usr/local/etc/gpu-guard.conf`; defaults fit NullMoth's NVIDIA Metal driver.
- Dry run mode (`GPU_GUARD_DRY=1`) that never touches the real attempt.
