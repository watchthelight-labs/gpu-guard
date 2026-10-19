# Contributing

The most useful report is a boot where the guard did the wrong thing: rolled back a boot you had confirmed, or kept one you hadn't. Open an issue with the Mac or laptop model, the GPU, the macOS build, the driver you were testing, your config file (minus anything private), `pending.json` from that attempt and the matching lines of `/Users/Shared/gpu-guard/gpu-guard.log`. If you got it working with a different driver, the settings you used are welcome too, so I can list them.

Pull requests: keep them small and say how you tested them. A dry run (`GPU_GUARD_DRY=1`) is fine for most changes; anything that touches the rollback path needs a real staged boot. I read and test every PR before merging. AI-assisted PRs are fine as long as you can explain the change, which is the same bar I hold my own code to.

Contributions are under the ISC licence, like the rest of the repo.
