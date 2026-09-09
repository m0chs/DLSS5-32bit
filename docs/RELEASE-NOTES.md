# v0.2.0-beta.1 — public review draft

A general ReShade/Feeder toolkit for eligible **32-bit DirectX 10/11 games**, prepared for m0chs/DLSS5-32bit. It has not been published.

- One menu for selecting a game, setting up, playing, checking, and disabling.
- PE architecture and import detection; explicit API override for known dynamic-loading games.
- Matched x86 Feeder and x64 helper, with pinned and verified rendering dependencies.
- Automatic host testing on the friendly Play path, reused only for matching host files/settings/GPU/driver.
- Reversible file activation, conflict checks, and local diagnostics.
- Explanation of the separate-process workaround and upstream credits.
- BO2 retained as a first technical test record, not a requirement of the installer.

**Limits:** D3D10 and other games are not locally validated. Correct scene depth, motion and image quality still need game-specific checking. DX9, Vulkan, OpenGL and x64 are not automated. This release uses the original RTX-50-targeted NR runtime.

The ZIP contains source/profile files only. All model/runtime/shader dependencies are downloaded separately to the user's machine. No game assets, raw personal logs, or proprietary runtime binaries are bundled.
