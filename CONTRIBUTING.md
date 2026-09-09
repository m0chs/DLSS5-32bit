# Contributing

This project is a setup/validation layer over upstream rendering work. Fix installation, recovery, API detection, documentation and test coverage here; report Feeder/consumer/runtime rendering faults to their respective projects with relevant evidence.

## Run tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Toolkit.ps1
pwsh.exe -NoProfile -File .\tests\Test-Toolkit.ps1
```

Tests build synthetic PE headers and temporary game folders. They do not launch games or run GPU inference. Keep a real game/helper closed when running file-lifecycle tests; the production process guards remain active.

The menu can be tested without interaction using `tools/Open-Menu.ps1 -Action Setup -GameExe <fixture> -PackageDirectory <fixture-package> -StateRoot <temporary-folder> -NonInteractive`.

## Add a game result

Architecture/API eligibility is not verification. Record the executable, API, exact component lock, GPU/driver, resolution, depth settings, motion provider, host test, observed visual result, and remaining problems. Separate measured facts from user reports and inference.

Add launcher-specific details to `game-profiles.json` only when known. Generic executable selection must continue to work without a catalog entry. Do not add online/anti-cheat bypass instructions.

## Change dependencies

Edit `components.lock.json` deliberately. Verify the asset and extracted member identities, architecture, and signer; update the Feeder client/helper/shader as one set. Document why a version changes and rerun appropriate tests. Do not replace pinned values with a mutable "latest" download or bundle restricted components.

## Build a reviewable source archive

```powershell
.\tools\New-SourceRelease.ps1
```

`release-files.json` is the exact public file allowlist. Update it when adding source files, then inspect the resulting ZIP. The builder never creates a GitHub repository, pushes a branch, or publishes a release. Raw logs, screenshots, binaries, model files, downloaded shader code, and local prototypes must stay out of the public archive.
