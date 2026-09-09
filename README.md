# DLSS5 for 32-bit games

A small Windows toolkit that sets up **community DLSS 5 neural rendering for eligible 32-bit DirectX 10/11 games**, using ReShade and a separate 64-bit helper.

**Experimental.** Neural rendering has run locally in Black Ops II campaign at 2560×1440. Other games still need testing, and correct depth, motion, and image quality are game dependent. This is a general installer; BO2 is the first test example. [What has been verified](docs/VALIDATION.md).

## Get started

1. [Download the beta release ZIP](https://github.com/m0chs/DLSS5-32bit/releases) and **extract it** into a normal local folder.
2. Double-click **`DLSS5-32bit.cmd`**. Choose **1 — Set up**, then paste the full path to the actual game `.exe`.
3. In the game's graphics settings, select its **DirectX 10/11 mode** if applicable and turn **MSAA off**. Start with SDR and windowed/borderless mode.
4. Use **offline single-player**, then choose **2 — Play game**. On first use, the helper runs a short GPU test before launching. Its result is reused while host files, settings, GPU and driver remain the same.
5. Press **Home → Add-ons → DLSS 5 Feed** to access settings. **F10** toggles effects for comparison.

Keep the launcher's console open while playing. After a normal exit, it parks the mod outside the game folder if it enabled the mod for that session. Use **4 — Disable mod** after a crash or manual activation.

If a game must start through Steam or another store launcher, choose **6 — Enable only**, launch it there, then choose **4 — Disable mod** after exiting. This manual route does not automatically disable the mod. Known launch details can be added to [game-profiles.json](game-profiles.json) without changing the generic installer.

**Setup does not patch your game executable.** Existing injectors and ReShade configurations are preserved and reported as conflicts. Different executables in the same directory share the proxy: do not start online/multiplayer modes while enabled. Known online executables and several anti-cheat markers are refused; this is not a complete anti-cheat detector.

## What you need

| Requirement | This release |
| --- | --- |
| Game architecture | **32-bit / x86** |
| Graphics API | Native **DirectX 10 or 11**; static import detection with an explicit override for known dynamic-loading games |
| GPU | **NVIDIA RTX 50-series** for the locked, original NR runtime |
| Windows | Windows with PowerShell 5.1 or 7; x86 and x64 Visual C++ v14 runtimes |
| Driver | Local bring-up used **616.56**; the built-in host test checks your combination |
| Game mode | Offline single-player |

DX9, Vulkan, OpenGL, and 64-bit games are **not automated by this release**. DLSS5-Feeder has additional backends, but those need different installation paths or wrappers. A 32-bit executable alone is not enough to establish compatibility.

## What this does

The toolkit installs a 32-bit ReShade/Feeder client beside the selected game and a 64-bit rendering stack in `host64`. The game shares its finished frame, depth, and estimated motion with the helper. The helper runs the NVIDIA neural pass and returns the image for presentation.

**DLSS5-Feeder supplies the cross-process bridge.** This repository supplies the setup menu, executable/API checks, pinned downloads, reversible installation, host-test integration, diagnostics, and documentation. We did not create a new NVIDIA model or invent the bridge.

It is a visual-processing experiment, not a conventional FPS upgrade: it adds work after the game renders, uses estimated motion, and does not add frame generation. [How the 32-bit workaround works](docs/HOW-IT-WORKS.md).

## Settings and first-run checks

Start with **NR Preset: Default**, the consumer's default style/intensities, **Enable Upscaling: Off**, **Work resolution: 100%**, and the masks/UI correction enabled. For a lower processing cost, try 75% work resolution with FSR 1 expand-back after native-size output is stable.

Natural/Cinematic are under **NR Style**, separate from the numbered **NR Preset** dropdown. Expand the triangle beside **DLSS 5 Feed** on ReShade's Add-ons page. The mirrored host settings require **Apply to the DLSS 5 host**; the displayed host panel allows live adjustments.

Depth orientation varies by game. This profile starts with ReShade's reversed-depth default `1`; verify the actual scene with DisplayDepth. **Depth inverted: Auto follows that configured value**, not an independent detection result. A running helper or a checked box does not prove valid scene depth.

[First-run and troubleshooting guide](docs/FIRST-RUN.md) · [Advanced commands](docs/COMMANDS.md)

## Credits and downloads

The rendering work belongs to **ReShade, DLSS5-Feeder, LumeniteFX, the RenoDX DLSS5 authors, and NVIDIA**. DLSS5oneclick was a reference installer. [Full credits and component terms](THIRD-PARTY.md).

The locked stack is ReShade 6.8.0, Feeder 0.14.0-beta.5, a pinned LumeniteFX Kernel snapshot, RenoDX DLSS5 4.55, and original NVIDIA 310.8.0 NR/SR DLLs. [Exact sources and hashes](components.lock.json).

The release contains **toolkit source and profiles only**. Runtime/model/shader dependencies are downloaded to your machine and retain their own terms; they are not bundled into the GitHub release. This is an unofficial integration, not an NVIDIA or game-developer release.

## Contributing

[Development and test instructions](CONTRIBUTING.md). Please report the exact executable/API, GPU/driver, resolution, component versions, and observed results. Logs are collected locally and never uploaded automatically.
